// The editor's Zoom, Media and Audio panels: zooming into moments, adding pictures, videos and blurs,
// and the sound tracks with the studio clean up.

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Zoom

struct ZoomPanel: View {
    @ObservedObject var ed: ReelEditor
    var body: some View {
        PanelTitle(title: "Zoom", subtitle: "Push in on what matters, like a camera. Each zoom eases in and out.", icon: "plus.magnifyingglass")
        WideButton(title: "Add a zoom at the playhead", icon: "plus.magnifyingglass", primary: true) { ed.addZoom() }
        if case .zoom(let id) = ed.selection, let z = ed.plan.zooms.first(where: { $0.id == id }) {
            PanelSection(title: "This zoom", trailing: AnyView(IconButton(icon: "trash", help: "Delete (⌫)", size: 11.5) { ed.deleteSelection() })) {
                Text("Drag the box to choose what to zoom in on.").font(.system(size: 11.5)).foregroundStyle(SC.dim)
                FocusPicker(ed: ed, zoom: z)
                Chips(options: [(1.25, "1.25×"), (1.5, "1.5×"), (1.8, "1.8×"), (2.2, "2.2×"), (3.0, "3×")], selection: ed.bindZoom(id, \.scale))
                ValueSlider(label: "Amount", value: ed.bindZoom(id, \.scale, undoable: false), range: 1.1...4, format: { String(format: "%.2f×", $0) }, reset: 1.8, onBegin: ed.beginChange)
                TimingRow(ed: ed, sel: .zoom(id), start: z.start, end: z.end)
            }
        }
        if !ed.plan.zooms.isEmpty {
            PanelSection(title: "Zooms") {
                ForEach(ed.plan.zooms) { z in
                    LayerRow(icon: "plus.magnifyingglass", title: String(format: "%.2g× zoom", z.scale), time: ed.timeline.outputSpan(of: TimeSpan(start: z.start, end: z.end))?.start) {
                        ed.select(.zoom(z.id))
                        if let s = ed.timeline.outputSpan(of: TimeSpan(start: z.start, end: z.end)) { ed.seek(s.start) }
                    }
                }
            }
        }
    }
}

/// The recording's frame at the start of a zoom, with a box showing what will fill the screen.
struct FocusPicker: View {
    @ObservedObject var ed: ReelEditor
    let zoom: ZoomItem
    @State private var frame: CGImage?
    @State private var start: CGPoint?
    var body: some View {
        let aspect = frame.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 16 / 9
        GeometryReader { geo in
            let w = geo.size.width, h = w / aspect
            let bw = w / zoom.scale, bh = h / zoom.scale
            let cx = min(max(zoom.x * w, bw / 2), w - bw / 2), cy = min(max(zoom.y * h, bh / 2), h - bh / 2)
            ZStack(alignment: .topLeading) {
                if let frame { Image(decorative: frame, scale: 1).resizable().frame(width: w, height: h) } else { Color.black.frame(width: w, height: h) }
                Color.black.opacity(0.45).frame(width: w, height: h)
                    .mask(Rectangle().fill(.white).overlay(Rectangle().frame(width: bw, height: bh).position(x: cx, y: cy).blendMode(.destinationOut)).compositingGroup())
                RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 2).frame(width: bw, height: bh).position(x: cx, y: cy)
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if start == nil { start = CGPoint(x: zoom.x, y: zoom.y); ed.beginChange() }
                    let nx = min(1, max(0, v.location.x / w)), ny = min(1, max(0, v.location.y / h))
                    if let i = ed.plan.zooms.firstIndex(where: { $0.id == zoom.id }) { ed.plan.zooms[i].x = nx; ed.plan.zooms[i].y = ny }
                }
                .onEnded { _ in start = nil })
        }
        .aspectRatio(aspect, contentMode: .fit)
        .task(id: zoom.start) { frame = await StudioFrames.frame(ed.url, at: zoom.start + 0.2) }
    }
}

// MARK: - Media

struct MediaPanel: View {
    @ObservedObject var ed: ReelEditor
    var body: some View {
        PanelTitle(title: "Media", subtitle: "Put a video, logo, photo or screenshot on top. You can also drop files anywhere on the editor.", icon: "photo.on.rectangle")
        HStack(spacing: 8) {
            AddTile(title: "Video", icon: "film", tint: "3B82F6") { openPanel([.movie]) { ed.addVideo($0) } }
            AddTile(title: "Picture", icon: "photo", tint: "F59E0B") { openPanel([.image]) { ed.addImage($0) } }
            AddTile(title: "Blur", icon: "eye.slash", tint: "EF4444") { ed.addBlur() }
        }
        if case .blur(let id) = ed.selection, let item = ed.plan.blurs.first(where: { $0.id == id }) {
            PanelSection(title: "Blur box", trailing: AnyView(IconButton(icon: "trash", help: "Delete (⌫)", size: 11.5) { ed.deleteSelection() })) {
                Text("Drag the box over what to hide; drag its corner to resize.").font(.system(size: 11.5)).foregroundStyle(SC.dim)
                BlurPicker(ed: ed, item: item)
                Chips(options: [("blur", "Blur"), ("pixelate", "Pixelate"), ("black", "Block out")], selection: Binding(
                    get: { item.style }, set: { v in ed.change { p in if let i = p.blurs.firstIndex(where: { $0.id == id }) { p.blurs[i].style = v } } }))
                if item.style != "black" {
                    ValueSlider(label: "Strength", value: Binding(get: { item.strength }, set: { v in if let i = ed.plan.blurs.firstIndex(where: { $0.id == id }) { ed.plan.blurs[i].strength = v } }),
                                range: 0...1, format: pct, reset: 0.6, onBegin: ed.beginChange)
                }
                TimingRow(ed: ed, sel: .blur(id), start: item.start, end: item.end)
                GhostButton(title: "Whole video", icon: "arrow.left.and.right") { ed.change { p in if let i = p.blurs.firstIndex(where: { $0.id == id }) { p.blurs[i].start = 0; p.blurs[i].end = ed.originalLength } } }
            }
        }
        if case .video(let id) = ed.selection, let item = ed.plan.videos.first(where: { $0.id == id }) {
            PanelSection(title: item.name, trailing: AnyView(IconButton(icon: "trash", help: "Delete (⌫)", size: 11.5) { ed.deleteSelection() })) {
                Chips(options: [(false, "Picture in picture"), (true, "Full screen")], selection: ed.bindVideo(id, \.full))
                if !item.full {
                    ValueSlider(label: "Size", value: ed.bindVideo(id, \.width, undoable: false), range: 0.15...1, format: pct, onBegin: ed.beginChange)
                    ValueSlider(label: "Rounded corners", value: ed.bindVideo(id, \.round, undoable: false), range: 0...0.5, format: pct, reset: 0.06, onBegin: ed.beginChange)
                    HStack(alignment: .top) {
                        PositionGrid(x: item.x, y: item.y) { x, y in ed.change { p in if let i = p.videos.firstIndex(where: { $0.id == id }) { p.videos[i].x = x; p.videos[i].y = y } } }
                        Spacer()
                        Text("Or drag it on the preview.").font(.system(size: 11.5)).foregroundStyle(SC.dim).frame(width: 110, alignment: .leading)
                    }
                }
                ValueSlider(label: "Its sound", value: ed.bindVideo(id, \.volume, undoable: false), range: 0...1, format: { $0 < 0.005 ? "Off" : pct($0) }, reset: 0, onBegin: ed.beginChange)
                TimingRow(ed: ed, sel: .video(id), start: item.start, end: item.end)
            }
        }
        if case .image(let id) = ed.selection, let item = ed.plan.images.first(where: { $0.id == id }) {
            PanelSection(title: item.name, trailing: AnyView(IconButton(icon: "trash", help: "Delete (⌫)", size: 11.5) { ed.deleteSelection() })) {
                ValueSlider(label: "Size", value: ed.bindImage(id, \.width, undoable: false), range: 0.04...1, format: pct, onBegin: ed.beginChange)
                ValueSlider(label: "Opacity", value: ed.bindImage(id, \.opacity, undoable: false), range: 0.05...1, format: pct, reset: 1, onBegin: ed.beginChange)
                ValueSlider(label: "Rounded corners", value: ed.bindImage(id, \.round, undoable: false), range: 0...0.5, format: pct, reset: 0, onBegin: ed.beginChange)
                HStack(alignment: .top) {
                    PositionGrid(x: item.x, y: item.y) { x, y in ed.change { p in if let i = p.images.firstIndex(where: { $0.id == id }) { p.images[i].x = x; p.images[i].y = y } } }
                    Spacer()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Or drag it on the preview.").font(.system(size: 11.5)).foregroundStyle(SC.dim)
                        GhostButton(title: "Whole video") { ed.change { p in if let i = p.images.firstIndex(where: { $0.id == id }) { p.images[i].start = 0; p.images[i].end = ed.originalLength } } }
                    }
                    .frame(width: 120, alignment: .leading)
                }
                TimingRow(ed: ed, sel: .image(id), start: item.start, end: item.end)
            }
        }
        if !ed.plan.videos.isEmpty || !ed.plan.images.isEmpty {
            PanelSection(title: "On this video") {
                ForEach(ed.plan.videos) { v in
                    LayerRow(icon: "film", title: v.name, time: ed.timeline.outputSpan(of: TimeSpan(start: v.start, end: v.end))?.start) { ed.select(.video(v.id)) }
                }
                ForEach(ed.plan.images) { i in
                    LayerRow(icon: "photo", title: i.name, time: ed.timeline.outputSpan(of: TimeSpan(start: i.start, end: i.end))?.start) { ed.select(.image(i.id)) }
                }
            }
        }
        PanelSection(title: "Progress bar", trailing: AnyView(Toggle("", isOn: Binding(get: { ed.plan.progressBar != nil },
                                                                                      set: { on in ed.change { $0.progressBar = on ? ProgressBar() : nil } }))
            .toggleStyle(.switch).controlSize(.small).labelsHidden().tint(SC.accent))) {
            Text("A thin bar that fills as the video plays, so people stay to the end.").font(.system(size: 11.5)).foregroundStyle(SC.dim)
            if ed.plan.progressBar != nil {
                Chips(options: [("top", "Top"), ("bottom", "Bottom")], selection: Binding(get: { ed.plan.progressBar?.position ?? "bottom" },
                                                                                          set: { v in ed.change { $0.progressBar?.position = v } }))
                Swatches(hex: Binding(get: { ed.plan.progressBar?.color.isEmpty == false ? ed.plan.progressBar!.color : ed.plan.captionStyle.accent },
                                      set: { v in ed.change { $0.progressBar?.color = v } }))
            }
        }
    }
}

/// A big square button for adding something, with its colour.
struct AddTile: View {
    let title: String
    let icon: String
    let tint: String
    var subtitle: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(LinearGradient(colors: [Color(nsColor: NSColor(hex: tint)), Color(nsColor: NSColor(hex: tint)).opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .shadow(color: Color(nsColor: NSColor(hex: tint)).opacity(0.5), radius: 8, y: 2)
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(SC.text)
                if let subtitle { Text(subtitle).font(.system(size: 10.5)).foregroundStyle(SC.dim).lineLimit(1) }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .studioCard(14)
        }
        .buttonStyle(Springy())
    }
}

// MARK: - Audio

struct AudioPanel: View {
    @ObservedObject var ed: ReelEditor
    var body: some View {
        PanelTitle(title: "Audio", subtitle: "Clean, clear voices, each track at the right level, and music that dips while you talk.", icon: "waveform")
        if ed.selection == .range, let r = ed.range {
            PanelSection(title: "This stretch  \(clock(r.start)) – \(clock(r.end))") {
                let p = ed.timeline.index(at: (r.start + r.end) / 2).map { ed.timeline.pieces[$0] }
                if ed.audioTracks > 1 {
                    ClipMix(ed: ed, mic: p?.mic ?? 1, sys: p?.sys ?? 1) { mic, sys in ed.setRange(mic: mic, sys: sys) }
                } else {
                    ValueSlider(label: "Volume", value: Binding(get: { p?.volume ?? 1 }, set: { ed.setRange(volume: $0) }), range: 0...2,
                                format: pct, reset: 1, onBegin: ed.beginChange)
                }
            }
        } else if let (_, clip) = ed.selectedClip {
            PanelSection(title: "This clip  \(clock(clip.out.start)) – \(clock(clip.out.end))") {
                ValueSlider(label: "Volume", value: Binding(get: { clip.volume }, set: { ed.setClip(volume: $0, for: clip) }), range: 0...2,
                            format: pct, reset: 1, onBegin: ed.beginChange)
                if ed.audioTracks > 1 {
                    ClipMix(ed: ed, mic: clip.mic, sys: clip.sys) { mic, sys in ed.setClip(mic: mic, sys: sys, for: clip) }
                }
            }
        } else if ed.audioTracks > 1 {
            Text("Pick a clip, or drag across the timeline, to give just that part its own mix of your mic and the computer sound.")
                .font(.system(size: 11.5)).foregroundStyle(SC.dim).fixedSize(horizontal: false, vertical: true)
        }
        PanelSection(title: "Tracks") {
            TrackRow(ed: ed, icon: "mic.fill", title: "Your microphone", detail: "You", volume: \.audio.micVolume)
            if ed.audioTracks > 1 {
                TrackRow(ed: ed, icon: "speaker.wave.2.fill", title: "Computer sound", detail: "The call, apps, videos", volume: \.audio.sysVolume)
            }
        }
        StudioSoundCard(ed: ed)
        PanelSection(title: "Start and end") {
            ValueSlider(label: "Fade in", value: ed.bind(\.audio.fadeIn, undoable: false), range: 0...3, format: secs, reset: 0, onBegin: ed.beginChange)
            ValueSlider(label: "Fade out", value: ed.bind(\.audio.fadeOut, undoable: false), range: 0...3, format: secs, reset: 0, onBegin: ed.beginChange)
        }
        PanelSection(title: "Music") {
            if let m = ed.plan.music {
                HStack(spacing: 8) {
                    Image(systemName: "music.note").foregroundStyle(SC.accent)
                    Text(m.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(SC.text).lineLimit(1)
                    Spacer()
                    IconButton(icon: "arrow.triangle.2.circlepath", help: "Replace", size: 11.5) { openPanel([.audio]) { ed.setMusic($0) } }
                    IconButton(icon: "trash", help: "Remove", size: 11.5) { ed.change { $0.music = nil } }
                }
                ValueSlider(label: "Volume", value: ed.bindMusic(\.volume, undoable: false), range: 0...1, format: pct, reset: 0.22, onBegin: ed.beginChange)
                Toggle("Quieter while people talk", isOn: ed.bindMusic(\.duck)).toggleStyle(.checkbox).font(.system(size: 12.5)).foregroundStyle(SC.text)
                ValueSlider(label: "Fade in", value: ed.bindMusic(\.fadeIn, undoable: false), range: 0...5, format: secs, reset: 1, onBegin: ed.beginChange)
                ValueSlider(label: "Fade out", value: ed.bindMusic(\.fadeOut, undoable: false), range: 0...5, format: secs, reset: 2, onBegin: ed.beginChange)
            } else {
                WideButton(title: "Add music…", icon: "music.note.list") { openPanel([.audio]) { ed.setMusic($0) } }
                Text("Any song file on your Mac. It loops to the length of the video. Use music you're allowed to post.")
                    .font(.system(size: 11.5)).foregroundStyle(SC.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One sound track: its volume and a mute button.
struct TrackRow: View {
    @ObservedObject var ed: ReelEditor
    let icon: String
    let title: String
    let detail: String
    let volume: WritableKeyPath<EditPlan, Double>
    var body: some View {
        let v = ed.plan[keyPath: volume]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(Circle().fill(v == 0 ? AnyShapeStyle(SC.faint) : AnyShapeStyle(SC.gradient)))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(SC.text)
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(SC.faint)
                }
                Spacer()
                Text(v == 0 ? "Muted" : pct(v)).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(SC.dim)
                IconButton(icon: v == 0 ? "speaker.slash.fill" : "speaker.wave.2", help: v == 0 ? "Unmute" : "Mute", size: 11.5) {
                    ed.change { $0[keyPath: volume] = v == 0 ? 1 : 0 }
                }
            }
            StudioSlider(value: ed.bind(volume, undoable: false), range: 0...2, onBegin: ed.beginChange)
        }
    }
}

/// Enhance speech, echo removal, polish and loudness.
struct StudioSoundCard: View {
    @ObservedObject var ed: ReelEditor
    var body: some View {
        let a = ed.plan.audio
        let two = ed.audioTracks > 1
        PanelSection(title: "Make it sound pro", trailing: ed.audioWork.map { p in AnyView(
            HStack(spacing: 6) {
                ProgressView(value: p).frame(width: 46).tint(SC.accent)
                Text("\(Int(p * 100))%").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(SC.dim)
            }) }) {
            option("wand.and.stars", "Enhance speech", "Apple's voice isolation, on your Mac. Background noise, room echo and chatter go; voices stay.",
                   on: a.micEnhance > 0 || a.sysEnhance > 0) { on in
                ed.change { $0.audio.micEnhance = on ? 0.85 : 0; $0.audio.sysEnhance = on && two ? 0.85 : 0 }
            }
            if a.micEnhance > 0 || a.sysEnhance > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    ValueSlider(label: "Strength", value: Binding(get: { max(a.micEnhance, a.sysEnhance) }, set: { v in
                        if ed.plan.audio.micEnhance > 0 { ed.plan.audio.micEnhance = v }
                        if ed.plan.audio.sysEnhance > 0 { ed.plan.audio.sysEnhance = v }
                    }), range: 0.2...1, format: pct, reset: 0.85, onBegin: ed.beginChange)
                    if two {
                        Chips(options: [(0, "Both"), (1, "My mic"), (2, "Computer")], selection: Binding(
                            get: { a.micEnhance > 0 && a.sysEnhance > 0 ? 0 : a.micEnhance > 0 ? 1 : 2 },
                            set: { v in let s = max(a.micEnhance, a.sysEnhance); ed.change { $0.audio.micEnhance = v != 2 ? s : 0; $0.audio.sysEnhance = v != 1 ? s : 0 } }))
                    }
                }
                .padding(.leading, 30)
            }
            if two {
                option("arrow.uturn.backward.circle", "Remove echo", ed.echoDelay.map { String(format: "Found your voice coming back %.2f s later in the computer sound.", $0) }
                       ?? "Your voice coming back through the call, from a second device or speakers.", on: a.echo) { on in ed.change { $0.audio.echo = on } }
            }
            option("slider.vertical.3", "Polish voice", "Low rumble cut, clearer and fuller, gently compressed and kept from clipping.", on: a.polish) { on in ed.change { $0.audio.polish = on } }
            option("chart.bar.xaxis", "Even out loudness", "Quiet phrases lifted, loud ones eased.", on: a.level) { on in ed.change { $0.audio.level = on } }
            VStack(alignment: .leading, spacing: 6) {
                Text("Loudness").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(SC.text)
                Chips(options: [("off", "As is"), ("social", "Social"), ("podcast", "Podcast"), ("broadcast", "TV")], selection: ed.bind(\.audio.loudness))
                Text(["social": "−14 LUFS, what Instagram, TikTok and YouTube play at.", "podcast": "−16 LUFS, the usual level for podcasts and Spotify.",
                      "broadcast": "−23 LUFS, the EBU broadcast standard."][a.loudness] ?? "Leaves the level as recorded.")
                    .font(.system(size: 11)).foregroundStyle(SC.faint)
            }
            let repeats = ed.repeats.count
            if repeats > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "repeat").font(.system(size: 12, weight: .semibold)).foregroundStyle(SC.gradient).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(repeats) repeat\(repeats == 1 ? "" : "s") found").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(SC.text)
                        Text("Words said twice and retakes.").font(.system(size: 11)).foregroundStyle(SC.faint)
                    }
                    Spacer()
                    Button { ed.removeRepeats() } label: {
                        Text("Remove").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 11).frame(height: 26).background(Capsule().fill(SC.gradient))
                    }
                    .buttonStyle(Springy())
                }
            }
            if ed.audioWork != nil {
                Text("Working on the sound in the background. The preview switches over when it's done.").font(.system(size: 11)).foregroundStyle(SC.faint)
            }
        }
    }

    private func option(_ icon: String, _ title: String, _ detail: String, on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? AnyShapeStyle(SC.gradient) : AnyShapeStyle(SC.faint)).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(SC.text)
                Text(detail).font(.system(size: 11)).foregroundStyle(SC.faint).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Toggle("", isOn: Binding(get: { on }, set: set)).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }
}

/// A frame of the recording with the blur box on it, to drag into place and resize.
struct BlurPicker: View {
    @ObservedObject var ed: ReelEditor
    let item: BlurItem
    @State private var frame: CGImage?
    @State private var start: BlurItem?
    var body: some View {
        let aspect = frame.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 16 / 9
        GeometryReader { geo in
            let w = geo.size.width, h = w / aspect
            let bw = w * item.w, bh = h * item.h
            ZStack(alignment: .topLeading) {
                if let frame { Image(decorative: frame, scale: 1).resizable().frame(width: w, height: h) } else { Color.black.frame(width: w, height: h) }
                RoundedRectangle(cornerRadius: 3).fill(Color.red.opacity(0.28))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white, lineWidth: 2))
                    .overlay(Image(systemName: "eye.slash.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
                    .frame(width: bw, height: bh)
                    .position(x: w * item.x, y: h * item.y)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if start == nil { start = item; ed.beginChange() }
                            guard let o = start, let i = ed.plan.blurs.firstIndex(where: { $0.id == item.id }) else { return }
                            ed.plan.blurs[i].x = min(1 - o.w / 2, max(o.w / 2, o.x + v.translation.width / w))
                            ed.plan.blurs[i].y = min(1 - o.h / 2, max(o.h / 2, o.y + v.translation.height / h))
                        }
                        .onEnded { _ in start = nil })
                Circle().fill(Color.white).frame(width: 12, height: 12).overlay(Circle().stroke(Color.red, lineWidth: 2))
                    .position(x: w * (item.x + item.w / 2), y: h * (item.y + item.h / 2))
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if start == nil { start = item; ed.beginChange() }
                            guard let o = start, let i = ed.plan.blurs.firstIndex(where: { $0.id == item.id }) else { return }
                            // Grows from the top-left corner, which stays put.
                            let left = o.x - o.w / 2, top = o.y - o.h / 2
                            let nw = min(1 - left, max(0.04, o.w + v.translation.width / w)), nh = min(1 - top, max(0.04, o.h + v.translation.height / h))
                            ed.plan.blurs[i].w = nw; ed.plan.blurs[i].h = nh
                            ed.plan.blurs[i].x = left + nw / 2; ed.plan.blurs[i].y = top + nh / 2
                        }
                        .onEnded { _ in start = nil })
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .aspectRatio(aspect, contentMode: .fit)
        .task(id: item.start) { frame = await StudioFrames.frame(ed.url, at: item.start + 0.2) }
    }
}
