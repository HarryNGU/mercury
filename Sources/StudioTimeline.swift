// The editor's timeline: a ruler and playhead, the video as clips with thumbnails and the sound
// underneath, and tracks for text, zooms, videos and pictures on top, captions and music. Mercury's own
// pause cuts show as fine marks inside a clip, so the recording reads as one piece you can trim and
// split anywhere. Click a clip to pick it, drag its ends to trim; drag text, zooms and overlays to
// move or stretch them; they snap to the playhead and cuts.

import AppKit
import AVFoundation
import SwiftUI

enum TrackColor {
    static let text = Color(nsColor: NSColor(hex: "8B5CF6"))
    static let zoom = Color(nsColor: NSColor(hex: "14B8A6"))
    static let video = Color(nsColor: NSColor(hex: "3B82F6"))
    static let image = Color(nsColor: NSColor(hex: "F59E0B"))
    static let music = Color(nsColor: NSColor(hex: "EC4899"))
    static let blur = Color(nsColor: NSColor(hex: "EF4444"))
}

struct StudioTimeline: View {
    @ObservedObject var ed: ReelEditor
    @StateObject private var thumbs = Thumbnails()
    @State private var zoomLevel = 1.0          // 1 = the whole video fits
    @State private var pinchStart: Double?
    @State private var visibleWidth: CGFloat = 800
    @State private var scrollX: CGFloat = 0
    @State private var position = ScrollPosition(edge: .leading)
    @State private var drag: Drag?
    @State private var scrubbing = false
    @State private var rangeAnchor: Double?

    struct Drag: Equatable {
        enum Kind { case move, start, end }
        var sel: Selection
        var kind: Kind
        var a: Double            // live start and end, edited seconds
        var b: Double
        var origin: (Double, Double)
        static func == (l: Drag, r: Drag) -> Bool { l.sel == r.sel && l.a == r.a && l.b == r.b }
    }

    private static let lead: CGFloat = 16
    private static let ruler: CGFloat = 24, laneH: CGFloat = 26, zoomH: CGFloat = 24, overlayH: CGFloat = 26, videoH: CGFloat = 70, capH: CGFloat = 20, musicH: CGFloat = 28
    private static let gap: CGFloat = 6

    /// Tall enough for every track that's in use.
    @MainActor static func height(for ed: ReelEditor) -> CGFloat {
        var ends: [Double] = []
        for t in ed.plan.texts.sorted(by: { $0.start < $1.start }) {
            if let i = ends.firstIndex(where: { $0 <= t.start + 0.01 }) { ends[i] = t.end } else { ends.append(t.end) }
        }
        let lanes = CGFloat(min(3, max(1, ends.count)))
        var h: CGFloat = 40 + 4 + ruler + lanes * laneH + zoomH + overlayH + videoH + capH + gap * (lanes + 5) + 12
        if !ed.plan.images.isEmpty && !ed.plan.videos.isEmpty { h += overlayH + gap }
        if ed.plan.music != nil { h += musicH + gap }
        return min(h, 440)
    }

    private var lead: CGFloat { Self.lead }
    private var duration: Double { max(0.1, ed.timeline.duration) }
    private var fitPPS: Double { max(0.2, Double(visibleWidth - lead - 40) / duration) }
    private var pps: Double { fitPPS * zoomLevel }
    private func x(_ t: Double) -> CGFloat { lead + CGFloat(t * pps) }
    private func t(_ x: CGFloat) -> Double { min(duration, max(0, Double(x - lead) / pps)) }
    private var contentWidth: CGFloat { max(visibleWidth, x(duration) + 60) }

    private var textLanes: [[TextItem]] {
        var lanes: [[TextItem]] = []
        var ends: [Double] = []
        for item in ed.plan.texts.sorted(by: { $0.start < $1.start }) {
            guard let span = span(of: .text(item.id)) else { continue }
            if let i = ends.firstIndex(where: { $0 <= span.start + 0.01 }) { lanes[i].append(item); ends[i] = span.end } else if lanes.count < 3 {
                lanes.append([item]); ends.append(span.end)
            } else { lanes[lanes.count - 1].append(item) }
        }
        return lanes.isEmpty ? [[]] : lanes
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                gutter
                GeometryReader { geo in
                    ScrollView(.horizontal) {
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: Self.gap) { tracks }
                            if let r = ed.range { rangeOverlay(r) }
                            playhead
                        }
                        .frame(width: contentWidth, alignment: .topLeading)
                        .padding(.top, 4)
                        .coordinateSpace(name: "timeline")
                    }
                    .scrollIndicators(.never)
                    .scrollPosition($position)
                    .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, v in scrollX = v }
                    .simultaneousGesture(MagnifyGesture()
                        .onChanged { v in
                            if pinchStart == nil { pinchStart = zoomLevel }
                            zoomLevel = min(80, max(1, (pinchStart ?? 1) * v.magnification))
                        }
                        .onEnded { _ in pinchStart = nil })
                    .onAppear { visibleWidth = geo.size.width }
                    .onChange(of: geo.size.width) { visibleWidth = geo.size.width }
                }
            }
        }
        .background(SC.bg)
        .onAppear { thumbs.setup(ed.url) }
        .onChange(of: ed.time) { follow() }
    }

    /// Keeps the playhead on screen while the video plays.
    private func follow() {
        guard ed.playing, zoomLevel > 1.01 else { return }
        let px = x(ed.time)
        if px > scrollX + visibleWidth - 50 || px < scrollX { position.scrollTo(x: max(0, px - 60)) }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                IconButton(icon: "scissors", help: "Split at the playhead (S)") { ed.split() }
                IconButton(icon: "trash", help: "Delete what's picked (⌫)") { ed.deleteSelection() }.disabled(ed.selection == .none)
                IconButton(icon: "plus.square.on.square", help: "Duplicate (⌘D)") { ed.duplicateSelection() }
                    .disabled({ if case .text = ed.selection { return false }; if case .zoom = ed.selection { return false }; return true }())
            }
            .padding(2).background(Capsule().fill(SC.wash(0.05))).overlay(Capsule().strokeBorder(SC.line))
            addChip("Text", "textformat", TrackColor.text) { ed.addText(ReelEditor.textPresets[0].item) }
            addChip("Zoom", "plus.magnifyingglass", TrackColor.zoom) { ed.addZoom() }
            addChip("Video", "film", TrackColor.video) { openPanel([.movie]) { ed.addVideo($0) } }
            addChip("Picture", "photo", TrackColor.image) { openPanel([.image]) { ed.addImage($0) } }
            addChip("Music", "music.note", TrackColor.music) { openPanel([.audio]) { ed.setMusic($0) } }
            addChip("Blur", "eye.slash", TrackColor.blur) { ed.addBlur() }
            Spacer(minLength: 8)
            Text(selectionLabel).font(.system(size: 11.5)).foregroundStyle(SC.faint).lineLimit(1)
                .contentTransition(.opacity).animation(.easeInOut(duration: 0.2), value: selectionLabel)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                IconButton(icon: "minus.magnifyingglass", help: "Zoom out", size: 12) { setZoom(zoomLevel / 1.5) }
                StudioSlider(value: Binding(get: { log2(zoomLevel) }, set: { setZoom(pow(2, $0)) }), range: 0...6.3).frame(width: 96)
                IconButton(icon: "plus.magnifyingglass", help: "Zoom in", size: 12) { setZoom(zoomLevel * 1.5) }
                Button { withAnimation(SC.spring) { setZoom(1) } } label: {
                    Text("Fit").font(.system(size: 11, weight: .semibold)).foregroundStyle(SC.text).fixedSize()
                        .padding(.horizontal, 9).frame(height: 22).background(Capsule().fill(SC.wash(0.08)))
                }
                .buttonStyle(Springy())
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(SC.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(SC.line).frame(height: 1) }
    }

    private func setZoom(_ z: Double) {
        let anchor = ed.time
        zoomLevel = min(80, max(1, z))
        DispatchQueue.main.async { position.scrollTo(x: max(0, x(anchor) - visibleWidth / 2)) }
    }

    private func addChip(_ title: String, _ icon: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
                Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(SC.text)
            }
            .padding(.horizontal, 9).frame(height: 26)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().strokeBorder(color.opacity(0.35)))
        }
        .buttonStyle(Springy()).help("Add \(title.lowercased())")
    }

    private var selectionLabel: String {
        switch ed.selection {
        case .none: return "Click the video to pick a clip · drag across it to pick a stretch · S splits at the playhead"
        case .piece: return ed.selectedClip.map { "Clip \(clock($0.clip.out.start)) – \(clock($0.clip.out.end)) · drag the ends to trim · S splits" } ?? ""
        case .text: return "Text · drag to move, drag the ends to stretch"
        case .zoom: return "Zoom · drag to move, drag the ends to stretch"
        case .image: return "Picture · drag to move, drag the ends to stretch"
        case .video: return "Video on top · drag to move, drag the ends to stretch"
        case .blur: return "Blur box · drag to move, drag the ends to stretch"
        case .music: return "Music · ⌫ removes it"
        case .range: return ed.range.map { "Picked \(clock($0.start)) – \(clock($0.end)) · drag the ends to adjust · ⌫ cuts it" } ?? ""
        }
    }

    // MARK: Rows

    private var gutter: some View {
        VStack(spacing: Self.gap) {
            Color.clear.frame(height: Self.ruler)
            ForEach(0..<textLanes.count, id: \.self) { i in icon(i == 0 ? "textformat" : "", Self.laneH, TrackColor.text) }
            icon("plus.magnifyingglass", Self.zoomH, TrackColor.zoom)
            if !ed.plan.images.isEmpty && !ed.plan.videos.isEmpty { icon("photo", Self.overlayH, TrackColor.image) }
            icon("square.on.square", Self.overlayH, TrackColor.video)
            icon("film", Self.videoH, SC.text)
            icon("captions.bubble", Self.capH, SC.dim)
            if ed.plan.music != nil { icon("music.note", Self.musicH, TrackColor.music) }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .frame(width: 38)
        .background(SC.panel)
        .overlay(alignment: .trailing) { Rectangle().fill(SC.line).frame(width: 1) }
    }

    private func icon(_ name: String, _ h: CGFloat, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 11, weight: .semibold)).foregroundStyle(color.opacity(0.85)).frame(height: h)
    }

    @ViewBuilder private var tracks: some View {
        rulerRow
        ForEach(Array(textLanes.enumerated()), id: \.offset) { i, lane in
            ZStack(alignment: .topLeading) {
                laneBackground(Self.laneH, hint: i == 0 && ed.plan.texts.isEmpty ? "Press T or click Text to add a title" : nil)
                ForEach(lane) { item in
                    block(.text(item.id), label: item.text.isEmpty ? "Text" : item.text, icon: "textformat", color: TrackColor.text, h: Self.laneH)
                }
            }
            .frame(height: Self.laneH)
        }
        ZStack(alignment: .topLeading) {
            laneBackground(Self.zoomH, hint: ed.plan.zooms.isEmpty && ed.plan.blurs.isEmpty ? "Press Z to zoom in at the playhead" : nil)
            ForEach(ed.plan.zooms) { z in
                block(.zoom(z.id), label: String(format: "%.2g× zoom", z.scale), icon: "plus.magnifyingglass", color: TrackColor.zoom, h: Self.zoomH)
            }
            ForEach(ed.plan.blurs) { b in
                block(.blur(b.id), label: b.style == "pixelate" ? "Pixelate" : b.style == "black" ? "Hidden" : "Blur", icon: "eye.slash", color: TrackColor.blur, h: Self.zoomH)
            }
        }
        .frame(height: Self.zoomH)
        // Pictures get their own track once there are videos on top too, so neither hides the other.
        if !ed.plan.images.isEmpty && !ed.plan.videos.isEmpty {
            ZStack(alignment: .topLeading) {
                laneBackground(Self.overlayH)
                ForEach(ed.plan.images) { i in block(.image(i.id), label: i.name, icon: "photo", color: TrackColor.image, h: Self.overlayH) }
            }
            .frame(height: Self.overlayH)
        }
        ZStack(alignment: .topLeading) {
            laneBackground(Self.overlayH, hint: ed.plan.videos.isEmpty && ed.plan.images.isEmpty ? "Drop a video or picture here to put it on top" : nil)
            if ed.plan.videos.isEmpty { ForEach(ed.plan.images) { i in block(.image(i.id), label: i.name, icon: "photo", color: TrackColor.image, h: Self.overlayH) } }
            ForEach(ed.plan.videos) { v in block(.video(v.id), label: v.name, icon: v.full ? "rectangle.fill" : "pip", color: TrackColor.video, h: Self.overlayH) }
        }
        .frame(height: Self.overlayH)
        videoRow
        captionRow
        if let m = ed.plan.music {
            let on = ed.selection == .music
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [TrackColor.music.opacity(on ? 0.75 : 0.45), TrackColor.music.opacity(on ? 0.5 : 0.25)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(on ? Color.white.opacity(0.85) : TrackColor.music.opacity(0.6), lineWidth: on ? 1.5 : 1))
                Label("\(m.name) · \(Int(m.volume * 100))%\(m.duck ? " · dips while you talk" : "")", systemImage: "music.note")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 10).lineLimit(1)
            }
            .frame(width: max(20, x(duration) - lead), height: Self.musicH)
            .shadow(color: on ? TrackColor.music.opacity(0.6) : .clear, radius: 8)
            .offset(x: lead)
            .onTapGesture { withAnimation(SC.spring) { ed.select(.music) } }
            .frame(height: Self.musicH, alignment: .leading)
        }
    }

    private func laneBackground(_ h: CGFloat, hint: String? = nil) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SC.wash(0.025))
            .frame(width: max(0, x(duration) - lead + 4), height: h)
            .overlay(alignment: .leading) {
                if let hint {
                    Text(hint).font(.system(size: 10.5)).foregroundStyle(SC.faint.opacity(0.8)).padding(.leading, 10).lineLimit(1)
                }
            }
            .offset(x: lead - 2)
            .frame(width: contentWidth, height: h, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { ed.selection = .none }
    }

    // MARK: Ruler and playhead

    private var rulerRow: some View {
        Canvas { ctx, size in
            let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
            let major = steps.first { $0 * pps >= 70 } ?? 600
            let minor = steps.last { $0 < major && $0 * pps >= 12 } ?? major
            let from = max(0, t(scrollX - 20)), to = min(duration, t(scrollX + visibleWidth + 20))
            var m = (from / minor).rounded(.down) * minor
            while m <= to + 0.0001 {
                let px = x(m)
                let isMajor = abs((m / major).rounded() * major - m) < 0.0001
                ctx.fill(Path(CGRect(x: px, y: size.height - (isMajor ? 8 : 4), width: 1, height: isMajor ? 8 : 4)), with: .color(SC.wash(isMajor ? 0.35 : 0.15)))
                if isMajor {
                    let label = major < 1 ? String(format: "%.1f", m) : clock(m).replacingOccurrences(of: ".0", with: "")
                    ctx.draw(Text(label).font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundColor(SC.washText(0.42)),
                             at: CGPoint(x: px + 4, y: 8), anchor: .leading)
                }
                m += minor
            }
        }
        .frame(width: contentWidth, height: Self.ruler)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if !scrubbing { scrubbing = true; ed.player.pause() }
                ed.seek(t(v.location.x))
            }
            .onEnded { _ in scrubbing = false })
    }

    private var playhead: some View {
        let px = x(ed.time)
        return ZStack(alignment: .top) {
            Rectangle().fill(SC.gradient).frame(width: 2).shadow(color: SC.accent.opacity(0.8), radius: 4)
            VStack(spacing: 0) {
                Circle().fill(Color.white).frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(SC.gradient, lineWidth: 3))
                    .shadow(color: SC.accent.opacity(0.8), radius: scrubbing ? 8 : 4)
                    .scaleEffect(scrubbing ? 1.25 : 1)
                    .animation(SC.spring, value: scrubbing)
                if scrubbing {
                    Text(clock(ed.time)).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(SC.gradient))
                        .fixedSize().offset(y: 4).transition(.scale.combined(with: .opacity))
                }
            }
            .offset(y: 4)
        }
        .frame(width: 16)
        .frame(maxHeight: .infinity)
        .offset(x: px - 8)
        .contentShape(Rectangle().size(width: 16, height: 24))
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { v in
                if !scrubbing { withAnimation(SC.spring) { scrubbing = true }; ed.player.pause() }
                ed.seek(t(v.location.x))
            }
            .onEnded { _ in withAnimation(SC.spring) { scrubbing = false } })
    }

    // MARK: Video

    private var videoRow: some View {
        let tl = ed.timeline
        let levels = ed.analysis?.levels ?? [], hop = ed.analysis?.hop ?? 0.02
        let selected = ed.selectedClip?.index
        let accent = SC.nsAccent
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                let videoH = Self.videoH
                let thumbH = videoH - 22
                let tileW = thumbH * thumbs.aspect
                let from = scrollX - 40, to = scrollX + visibleWidth + 40
                for (ci, clip) in tl.clips.enumerated() {
                    var x0 = x(clip.out.start), x1 = x(clip.out.end)
                    if drag?.sel == .piece(clip.src.start), let d = drag { x0 = x(d.a); x1 = x(d.b) }
                    guard x1 >= from, x0 <= to else { continue }
                    let rect = CGRect(x: x0 + 1, y: 0, width: max(3, x1 - x0 - 2), height: videoH)
                    let shape = Path(roundedRect: rect, cornerRadius: 10, style: .continuous)
                    let isSel = ci == selected
                    if isSel { ctx.drawLayer { c in c.addFilter(.shadow(color: Color(nsColor: accent).opacity(0.7), radius: 10)); c.fill(shape, with: .color(Color(nsColor: accent))) } }
                    ctx.drawLayer { c in
                        c.clip(to: shape)
                        c.fill(shape, with: .color(SC.dark ? Color(white: 0.11) : Color(white: 0.88)))
                        // Thumbnails along the top, from whichever piece is under each tile.
                        var tx = rect.minX
                        while tx < rect.maxX {
                            if tx + tileW >= from && tx <= to {
                                let ot = t(tx + tileW / 2)
                                let pi = tl.index(at: ot) ?? clip.pieces.lowerBound
                                let p = tl.pieces[min(max(pi, clip.pieces.lowerBound), clip.pieces.upperBound - 1)]
                                let s = tl.source(at: min(max(ot, p.out.start), p.out.end))
                                if let img = thumbs.image(near: s, step: Double(tileW) / pps * p.speed) {
                                    c.draw(Image(decorative: img, scale: 1), in: CGRect(x: tx, y: 0, width: tileW, height: thumbH))
                                }
                            }
                            tx += tileW
                        }
                        // A soft shade so the sound reads clearly.
                        let band = SC.dark ? Color.black.opacity(0.85) : Color.white.opacity(0.9)
                        c.fill(Path(CGRect(x: rect.minX, y: thumbH - 10, width: rect.width, height: 32)),
                               with: .linearGradient(Gradient(colors: [.clear, band]), startPoint: CGPoint(x: 0, y: thumbH - 10), endPoint: CGPoint(x: 0, y: thumbH + 6)))
                        c.fill(Path(CGRect(x: rect.minX, y: thumbH, width: rect.width, height: 22)), with: .color(SC.dark ? Color.black.opacity(0.55) : Color.white.opacity(0.75)))
                        if !levels.isEmpty {
                            var wave = Path()
                            var px = max(rect.minX, from)
                            while px < min(rect.maxX, to) {
                                let ot = t(px)
                                if let pi = tl.index(at: ot) {
                                    let p = tl.pieces[pi]
                                    let s = tl.source(at: ot)
                                    let li = min(levels.count - 1, max(0, Int(s / hop)))
                                    let h = CGFloat(min(1, max(0, (Double(levels[li]) + 58) / 46))) * 18 * CGFloat(min(1.5, p.volume))
                                    wave.addRoundedRect(in: CGRect(x: px, y: videoH - 2 - h, width: 1.6, height: max(0.8, h)), cornerSize: CGSize(width: 0.8, height: 0.8))
                                }
                                px += 2.6
                            }
                            c.fill(wave, with: .linearGradient(Gradient(colors: [Color(nsColor: SC.ends.0), Color(nsColor: SC.ends.1)]),
                                                                startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
                        }
                        // Mercury's pause cuts: fine marks inside the clip.
                        for pi in clip.pieces.dropFirst() where tl.pieces[pi].afterCut {
                            let mx = x(tl.pieces[pi].out.start)
                            guard mx > from, mx < to else { continue }
                            c.fill(Path(CGRect(x: mx - 0.5, y: 0, width: 1, height: thumbH)), with: .color(Color.black.opacity(0.55)))
                            c.fill(Path(CGRect(x: mx + 0.5, y: 0, width: 0.5, height: thumbH)), with: .color(SC.wash(0.12)))
                        }
                    }
                    ctx.stroke(shape, with: isSel ? .color(SC.wash(0.95)) : .color(SC.wash(0.1)), lineWidth: isSel ? 2 : 1)
                    // Speed and volume badges.
                    var badge = ""
                    if abs(clip.speed - ed.plan.speed) > 0.001 { badge += String(format: "%.2g×", clip.speed / max(0.01, ed.plan.speed)) }
                    if clip.volume == 0 { badge += badge.isEmpty ? "muted" : " · muted" } else if abs(clip.volume - 1) > 0.01 { badge += (badge.isEmpty ? "" : " · ") + "\(Int(clip.volume * 100))%" }
                    // Its own mix of your mic and the computer's sound.
                    if abs(clip.mic - 1) > 0.01 || abs(clip.sys - 1) > 0.01 {
                        badge += (badge.isEmpty ? "" : " · ") + "mic \(Int((clip.mic * 100).rounded()))% · pc \(Int((clip.sys * 100).rounded()))%"
                    }
                    if !badge.isEmpty, rect.width > 44 {
                        let r = CGRect(x: rect.minX + 6, y: 6, width: CGFloat(badge.count) * 6.2 + 12, height: 16)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 8), with: .color(Color(nsColor: accent)))
                        ctx.draw(Text(badge).font(.system(size: 9.5, weight: .bold)).foregroundColor(.white), at: CGPoint(x: r.midX, y: r.midY))
                    }
                }
            }
            .frame(width: contentWidth, height: Self.videoH)
            .contentShape(Rectangle())
            // Press and drag across the video to pick a stretch of it.
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { v in
                    if rangeAnchor == nil { rangeAnchor = t(v.startLocation.x); ed.player.pause(); NSApp.keyWindow?.makeFirstResponder(nil) }
                    ed.selectRange(rangeAnchor ?? 0, t(v.location.x))
                    ed.seek(t(v.location.x))
                }
                .onEnded { _ in rangeAnchor = nil; if let r = ed.range { ed.seek(r.start) } })
            .simultaneousGesture(SpatialTapGesture().onEnded { v in
                NSApp.keyWindow?.makeFirstResponder(nil)
                let tt = t(v.location.x)
                if let i = ed.timeline.clipIndex(at: tt), tt <= ed.timeline.clips[i].out.end {
                    withAnimation(SC.spring) { ed.select(.piece(ed.timeline.clips[i].src.start)) }
                } else { ed.selection = .none }
                ed.seek(tt)
            })
            if let (i, c) = ed.selectedClip { trimHandles(i, c) }
        }
        .frame(height: Self.videoH)
    }

    private func trimHandles(_ i: Int, _ c: Clip) -> some View {
        let live = drag?.sel == .piece(c.src.start) ? drag : nil
        let x0 = x(live?.a ?? c.out.start), x1 = x(live?.b ?? c.out.end)
        return ZStack(alignment: .topLeading) {
            handle(left: true).offset(x: x0 - 1).gesture(trim(i, c, start: true))
            handle(left: false).offset(x: x1 - 13).gesture(trim(i, c, start: false))
            if let live {
                let shown = live.kind == .start ? live.a : live.b
                Text(clock(shown)).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(SC.gradient))
                    .shadow(color: SC.accent.opacity(0.6), radius: 6)
                    .fixedSize()
                    .offset(x: x(shown) - 28, y: -12)
            }
        }
    }

    private func handle(left: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: left ? 10 : 3, bottomLeadingRadius: left ? 10 : 3, bottomTrailingRadius: left ? 3 : 10, topTrailingRadius: left ? 3 : 10, style: .continuous)
            .fill(Color.white)
            .overlay(VStack(spacing: 3) { ForEach(0..<3) { _ in Circle().fill(SC.accent).frame(width: 3, height: 3) } })
            .frame(width: 14, height: Self.videoH)
            .shadow(color: SC.accent.opacity(0.6), radius: 6)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    private func trim(_ i: Int, _ c: Clip, start: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                let dt = Double(v.translation.width) / pps
                var a = c.out.start, b = c.out.end
                if start { a = min(b - 0.1, max(0, c.out.start + dt)) } else { b = max(a + 0.1, c.out.end + dt) }
                drag = Drag(sel: .piece(c.src.start), kind: start ? .start : .end, a: a, b: b, origin: (c.out.start, c.out.end))
            }
            .onEnded { v in
                let dt = Double(v.translation.width) / pps
                drag = nil
                guard abs(dt) > 0.01 else { return }
                ed.beginChange()
                // Through the edited time, so pause cuts inside the clip count the way they look.
                let target = start ? ed.timeline.source(at: max(0, c.out.start + dt)) : ed.timeline.source(at: min(ed.timeline.duration, c.out.end + dt), preferEnd: true)
                let beyond = start ? c.src.start + min(0, dt) * c.speed : c.src.end + max(0, dt) * c.speed
                let inside = start ? dt > 0 : dt < 0
                ed.trim(i, start: start, to: inside ? target : beyond)
            }
    }

    // MARK: A picked stretch

    private func rangeOverlay(_ r: TimeSpan) -> some View {
        let x0 = x(r.start), x1 = x(r.end)
        let top = Self.ruler + 4
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SC.accent.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SC.gradient, lineWidth: 1.5))
                .frame(width: max(2, x1 - x0))
                .frame(maxHeight: .infinity)
                .offset(x: x0)
                .allowsHitTesting(false)
            Text("\(String(format: "%.1f", r.end - r.start)) s").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(SC.gradient))
                .shadow(color: SC.accent.opacity(0.5), radius: 5)
                .fixedSize()
                .offset(x: (x0 + x1) / 2 - 22, y: -top + 3)
                .allowsHitTesting(false)
            rangeHandle().offset(x: x0 - 7).gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { v in
                ed.selectRange(min(t(v.location.x), r.end - 0.05), r.end); ed.seek(r.start)
            })
            rangeHandle().offset(x: x1 - 7).gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { v in
                ed.selectRange(r.start, max(t(v.location.x), r.start + 0.05)); ed.seek(r.end)
            })
        }
        .padding(.top, top)
        .transition(.opacity)
    }

    private func rangeHandle() -> some View {
        Capsule().fill(Color.white)
            .overlay(VStack(spacing: 3) { ForEach(0..<3) { _ in Circle().fill(SC.accent).frame(width: 3, height: 3) } })
            .frame(width: 14, height: 42)
            .shadow(color: SC.accent.opacity(0.7), radius: 6)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    // MARK: Captions

    private var captionRow: some View {
        let cues = ed.cues
        let accent = SC.nsAccent
        return Canvas { ctx, size in
            let from = t(scrollX - 20), to = t(scrollX + visibleWidth + 20)
            for c in cues where c.end >= from && c.start <= to {
                let r = CGRect(x: x(c.start) + 0.5, y: 1, width: max(2, x(c.end) - x(c.start) - 1), height: Self.capH - 2)
                let now = ed.time >= c.start && ed.time < c.end
                ctx.fill(Path(roundedRect: r, cornerRadius: 5), with: .color(now ? Color(nsColor: accent).opacity(0.45) : SC.wash(0.06)))
                if r.width > 24 {
                    var c2 = ctx
                    c2.clip(to: Path(r.insetBy(dx: 4, dy: 0)))
                    c2.draw(Text(c.text).font(.system(size: 9.5, weight: now ? .semibold : .regular)).foregroundColor(SC.washText(now ? 0.95 : 0.5)),
                            at: CGPoint(x: r.minX + 5, y: r.midY), anchor: .leading)
                }
            }
        }
        .frame(width: contentWidth, height: Self.capH)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { v in
            let tt = t(v.location.x)
            if let c = cues.first(where: { tt >= $0.start && tt < $0.end }) { ed.seek(c.start + 0.01); ed.tool = .captions } else { ed.seek(tt) }
        })
    }

    // MARK: Blocks (text, zoom, pictures, videos)

    private func span(of s: Selection) -> TimeSpan? {
        if let d = drag, d.sel == s { return TimeSpan(start: d.a, end: d.b) }
        switch s {
        case .text(let id): return ed.plan.texts.first { $0.id == id }.flatMap { ed.timeline.outputSpan(of: TimeSpan(start: $0.start, end: $0.end)) }
        case .zoom(let id): return ed.plan.zooms.first { $0.id == id }.flatMap { ed.timeline.outputSpan(of: TimeSpan(start: $0.start, end: $0.end)) }
        case .image(let id): return ed.plan.images.first { $0.id == id }.flatMap { ed.timeline.outputSpan(of: TimeSpan(start: $0.start, end: $0.end)) }
        case .video(let id): return ed.plan.videos.first { $0.id == id }.flatMap { ed.timeline.outputSpan(of: TimeSpan(start: $0.start, end: $0.end)) }
        case .blur(let id): return ed.plan.blurs.first { $0.id == id }.flatMap { ed.timeline.outputSpan(of: TimeSpan(start: $0.start, end: $0.end)) }
        default: return nil
        }
    }

    @ViewBuilder private func block(_ sel: Selection, label: String, icon: String, color: Color, h: CGFloat) -> some View {
        if let sp = span(of: sel) {
            let selected = ed.selection == sel
            let w = max(10, x(sp.end) - x(sp.start))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [color.opacity(selected ? 1 : 0.75), color.opacity(selected ? 0.75 : 0.5)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? Color.white.opacity(0.95) : Color.white.opacity(0.18), lineWidth: selected ? 1.5 : 1))
                if w > 28 {
                    Label(label, systemImage: icon).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        .padding(.horizontal, 8)
                }
                if selected {
                    HStack {
                        edge(sel, sp, start: true)
                        Spacer(minLength: 0)
                        edge(sel, sp, start: false)
                    }
                }
            }
            .frame(width: w, height: h - 2)
            .shadow(color: selected ? color.opacity(0.7) : .clear, radius: 8)
            .scaleEffect(y: selected ? 1.04 : 1)
            .animation(SC.spring, value: selected)
            .offset(x: x(sp.start), y: 1)
            .onTapGesture { withAnimation(SC.spring) { ed.select(sel) } }
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { v in
                    let o = drag?.origin ?? (sp.start, sp.end)
                    let len = o.1 - o.0
                    var a = min(max(0, o.0 + Double(v.translation.width) / pps), duration - len)
                    a = snap(a, len: len)
                    drag = Drag(sel: sel, kind: .move, a: a, b: a + len, origin: o)
                    if ed.selection != sel { ed.select(sel) }
                }
                .onEnded { _ in commit() })
        }
    }

    private func edge(_ sel: Selection, _ sp: TimeSpan, start: Bool) -> some View {
        Capsule().fill(Color.white).frame(width: 4)
            .padding(.vertical, 5).padding(.horizontal, 2)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let o = drag?.origin ?? (sp.start, sp.end)
                    let dt = Double(v.translation.width) / pps
                    var a = o.0, b = o.1
                    if start { a = snapPoint(min(b - 0.2, max(0, o.0 + dt))) } else { b = snapPoint(max(a + 0.2, min(duration, o.1 + dt))) }
                    drag = Drag(sel: sel, kind: start ? .start : .end, a: a, b: b, origin: o)
                }
                .onEnded { _ in commit() })
    }

    private func commit() {
        guard let d = drag else { return }
        drag = nil
        guard abs(d.a - d.origin.0) > 0.005 || abs(d.b - d.origin.1) > 0.005 else { return }
        ed.beginChange()
        ed.setSpan(d.sel, from: d.a, to: d.b)
    }

    /// Lines things up with the playhead and the joins between clips when they're close.
    private func snapPoint(_ v: Double) -> Double {
        let reach = 8 / pps
        let targets = [ed.time, 0, duration] + ed.timeline.clips.map(\.out.end)
        return targets.min { abs($0 - v) < abs($1 - v) }.flatMap { abs($0 - v) < reach ? $0 : nil } ?? v
    }

    private func snap(_ a: Double, len: Double) -> Double {
        let s = snapPoint(a)
        if s != a { return s }
        let e = snapPoint(a + len)
        return e != a + len ? e - len : a
    }
}

// MARK: - Thumbnails

/// Small frames of the recording for the timeline, made as they're needed and kept.
@MainActor
final class Thumbnails: ObservableObject {
    @Published private(set) var images: [Int: CGImage] = [:]
    private(set) var aspect: CGFloat = 16 / 9
    private var generator: AVAssetImageGenerator?
    private var pending = Set<Int>()
    private var queue: [Int] = []
    private var running = false

    func setup(_ url: URL) {
        guard generator == nil else { return }
        let asset = AVURLAsset(url: url)
        let g = AVAssetImageGenerator(asset: asset)
        g.maximumSize = CGSize(width: 220, height: 220)
        g.appliesPreferredTrackTransform = true
        g.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        g.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator = g
        Task {
            if let v = try? await asset.loadTracks(withMediaType: .video).first, let s = try? await v.load(.naturalSize), s.height > 0 {
                aspect = s.width / s.height
                objectWillChange.send()
            }
        }
    }

    /// The frame nearest a moment, on a grid that suits how zoomed in the timeline is.
    func image(near s: Double, step: Double) -> CGImage? {
        let grid: [Double] = [0.25, 0.5, 1, 2, 5, 10, 20, 30, 60, 120]
        let g = grid.first { $0 >= step } ?? 120
        let key = Int(((s / g).rounded() * g) * 10)
        if let img = images[key] { return img }
        if !pending.contains(key) {
            pending.insert(key)
            DispatchQueue.main.async { self.queue.append(key); self.pump() }
        }
        // Meanwhile, the closest one already made.
        return images.min { abs($0.key - key) < abs($1.key - key) }.flatMap { abs($0.key - key) < Int(g * 40) ? $0.value : nil }
    }

    private func pump() {
        guard !running, let g = generator, !queue.isEmpty else { return }
        running = true
        let batch = Array(queue.prefix(12))
        queue.removeFirst(batch.count)
        Task {
            for await r in g.images(for: batch.map { CMTime(seconds: Double($0) / 10, preferredTimescale: 600) }) {
                let key = Int((r.requestedTime.seconds * 10).rounded())
                if let img = try? r.image { images[key] = img }
            }
            running = false
            pump()
        }
    }
}
