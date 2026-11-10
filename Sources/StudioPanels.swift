// The editor's tool panels, down the left beside the rail: Edit, Text, Subtitles, Transcript, Zoom,
// Media, Audio, Canvas, Colour and Claude. Picking something on the timeline opens its panel.

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct StudioPanel: View {
    @ObservedObject var ed: ReelEditor

    var body: some View {
        ZStack {
            switch ed.tool {
            case .transcript: TranscriptPanel(ed: ed)
            case .claude: ClaudePanel(ed: ed, url: ed.url)
            default:
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch ed.tool {
                        case .edit: EditPanel(ed: ed)
                        case .text: TextPanel(ed: ed)
                        case .captions: CaptionsPanel(ed: ed)
                        case .zoom: ZoomPanel(ed: ed)
                        case .media: MediaPanel(ed: ed)
                        case .audio: AudioPanel(ed: ed)
                        case .canvas: CanvasPanel(ed: ed)
                        case .colour: ColourPanel(ed: ed)
                        default: EmptyView()
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
            }
        }
        .id(ed.tool)
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
        .tint(SC.accent)
    }
}

// MARK: - Building blocks

extension ReelEditor {
    /// A setting on the edit. Buttons and pickers make an undo step; sliders mark theirs when the drag starts.
    func bind<T>(_ kp: WritableKeyPath<EditPlan, T>, undoable: Bool = true) -> Binding<T> {
        Binding(get: { self.plan[keyPath: kp] }, set: { v in if undoable { self.change { $0[keyPath: kp] = v } } else { self.plan[keyPath: kp] = v } })
    }

    func bindText<T>(_ id: UUID, _ kp: WritableKeyPath<TextItem, T>, undoable: Bool = true) -> Binding<T> {
        Binding(get: { self.plan.texts.first { $0.id == id }.map { $0[keyPath: kp] } ?? TextItem(text: "", start: 0, end: 0)[keyPath: kp] },
                set: { v in
                    guard let i = self.plan.texts.firstIndex(where: { $0.id == id }) else { return }
                    if undoable { self.change { $0.texts[i][keyPath: kp] = v } } else { self.plan.texts[i][keyPath: kp] = v }
                })
    }

    func bindZoom<T>(_ id: UUID, _ kp: WritableKeyPath<ZoomItem, T>, undoable: Bool = true) -> Binding<T> {
        Binding(get: { self.plan.zooms.first { $0.id == id }.map { $0[keyPath: kp] } ?? ZoomItem(start: 0, end: 0)[keyPath: kp] },
                set: { v in
                    guard let i = self.plan.zooms.firstIndex(where: { $0.id == id }) else { return }
                    if undoable { self.change { $0.zooms[i][keyPath: kp] = v } } else { self.plan.zooms[i][keyPath: kp] = v }
                })
    }

    func bindImage<T>(_ id: UUID, _ kp: WritableKeyPath<ImageItem, T>, undoable: Bool = true) -> Binding<T> {
        Binding(get: { self.plan.images.first { $0.id == id }.map { $0[keyPath: kp] } ?? ImageItem(file: "", name: "", start: 0, end: 0)[keyPath: kp] },
                set: { v in
                    guard let i = self.plan.images.firstIndex(where: { $0.id == id }) else { return }
                    if undoable { self.change { $0.images[i][keyPath: kp] = v } } else { self.plan.images[i][keyPath: kp] = v }
                })
    }

    func bindVideo<T>(_ id: UUID, _ kp: WritableKeyPath<VideoItem, T>, undoable: Bool = true) -> Binding<T> {
        Binding(get: { self.plan.videos.first { $0.id == id }.map { $0[keyPath: kp] } ?? VideoItem(file: "", name: "", start: 0, end: 0)[keyPath: kp] },
                set: { v in
                    guard let i = self.plan.videos.firstIndex(where: { $0.id == id }) else { return }
                    if undoable { self.change { $0.videos[i][keyPath: kp] = v } } else { self.plan.videos[i][keyPath: kp] = v }
                })
    }

    func bindMusic<T>(_ kp: WritableKeyPath<MusicTrack, T>, undoable: Bool = true) -> Binding<T> {
        Binding(get: { (self.plan.music ?? MusicTrack(file: "", name: ""))[keyPath: kp] },
                set: { v in
                    guard self.plan.music != nil else { return }
                    if undoable { self.change { $0.music![keyPath: kp] = v } } else { self.plan.music![keyPath: kp] = v }
                })
    }
}

struct PanelTitle: View {
    let title: String
    var subtitle: String?
    var icon: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SC.gradient))
                        .shadow(color: SC.accent.opacity(0.45), radius: 8, y: 2)
                }
                Text(title).font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(SC.text)
            }
            if let subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(SC.dim).fixedSize(horizontal: false, vertical: true).lineSpacing(1.5)
            }
        }
        .padding(.bottom, 2)
    }
}

struct PanelSection<Content: View>: View {
    let title: String
    var trailing: AnyView?
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Circle().fill(SC.gradient).frame(width: 5, height: 5)
                Text(title.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(0.9).foregroundStyle(SC.dim).lineLimit(1)
                Spacer()
                trailing
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioCard(16)
    }
}

struct ValueSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var reset: Double?
    let onBegin: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.system(size: 12.5)).foregroundStyle(SC.text)
                Spacer()
                Text(format(value)).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(SC.dim)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(SC.wash(0.06)))
                    .onTapGesture(count: 2) { if let r = reset { onBegin(); withAnimation(SC.spring) { value = r } } }
                    .help(reset == nil ? "" : "Double-click to reset")
            }
            StudioSlider(value: $value, range: range, onBegin: onBegin)
        }
    }
}

struct Chips<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var columns = 0
    @Namespace private var pill
    var body: some View {
        let cols = columns > 0 ? columns : options.count
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: cols), spacing: 5) {
            ForEach(options.indices, id: \.self) { i in
                let (v, label) = options[i]
                let on = selection == v
                Button { withAnimation(SC.spring) { selection = v } } label: {
                    Text(label).font(.system(size: 11.5, weight: on ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.75)
                        .foregroundStyle(on ? .white : SC.dim)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SC.gradient)
                                    .shadow(color: SC.accent.opacity(0.4), radius: 6, y: 2)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            } else {
                                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SC.wash(0.045))
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(on ? Color.white.opacity(0.2) : SC.line, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(Springy())
            }
        }
    }
}

struct Swatches: View {
    @Binding var hex: String
    var colors = ["FFFFFF", "111111", "FFD60A", "FF453A", "FF9F0A", "30D158", "64D2FF", "0A84FF", "BF5AF2", "FF6FB5"]
    var body: some View {
        HStack(spacing: 7) {
            ForEach(colors, id: \.self) { c in
                let on = hex.uppercased() == c
                Circle().fill(Color(nsColor: NSColor(hex: c))).frame(width: 19, height: 19)
                    .overlay(Circle().strokeBorder(SC.wash(0.18), lineWidth: 1))
                    .overlay(Circle().stroke(SC.gradient, lineWidth: 2).padding(-3.5).opacity(on ? 1 : 0))
                    .scaleEffect(on ? 1.08 : 1)
                    .animation(SC.spring, value: on)
                    .onTapGesture { hex = c }
            }
            ColorPicker("", selection: Binding(get: { Color(nsColor: NSColor(hex: hex)) }, set: { hex = NSColor($0).hex }), supportsOpacity: false)
                .labelsHidden().frame(width: 24)
        }
    }
}

/// Nine spots to put something.
struct PositionGrid: View {
    let x: Double
    let y: Double
    let set: (Double, Double) -> Void
    var body: some View {
        let spots: [Double] = [0.15, 0.5, 0.85]
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<3) { r in
                GridRow {
                    ForEach(0..<3) { c in
                        let on = abs(x - spots[c]) < 0.08 && abs(y - spots[r]) < 0.08
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? AnyShapeStyle(SC.gradient) : AnyShapeStyle(SC.wash(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(SC.line))
                            .frame(width: 30, height: 20)
                            .glow(on, radius: 5)
                            .onTapGesture { withAnimation(SC.spring) { set(spots[c], spots[r]) } }
                    }
                }
            }
        }
        .padding(6).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25)))
    }
}

struct WideButton: View {
    let title: String
    var icon: String?
    var primary = false
    let action: () -> Void
    var body: some View {
        if primary { GlowButton(title: title, icon: icon, height: 36, full: true, action: action) } else { GhostButton(title: title, icon: icon, full: true, action: action) }
    }
}

/// When a layer starts and ends, with buttons to move either end to the playhead.
struct TimingRow: View {
    @ObservedObject var ed: ReelEditor
    let sel: Selection
    let start: Double
    let end: Double
    var body: some View {
        let span = ed.timeline.outputSpan(of: TimeSpan(start: start, end: end))
        VStack(spacing: 6) {
            row("Starts", span?.start) { ed.beginChange(); ed.setSpan(sel, from: ed.time, to: span?.end ?? ed.time + 2) }
            row("Ends", span?.end) { ed.beginChange(); ed.setSpan(sel, from: span?.start ?? max(0, ed.time - 2), to: ed.time) }
        }
    }
    private func row(_ label: String, _ t: Double?, _ action: @escaping () -> Void) -> some View {
        HStack {
            Text(label).font(.system(size: 12.5)).foregroundStyle(SC.text)
            Spacer()
            Text(t.map(clock) ?? "cut").font(.system(size: 11, design: .monospaced)).foregroundStyle(SC.dim)
                .onTapGesture { if let t { ed.seek(t) } }
            Button(action: action) {
                Label("Playhead", systemImage: "arrow.down.to.line").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(SC.text)
                    .padding(.horizontal, 8).frame(height: 22).background(Capsule().fill(SC.wash(0.08)))
            }
            .buttonStyle(Springy()).help("Move to the playhead")
        }
    }
}

/// A text box in the studio's style.
struct StudioField: View {
    let placeholder: String
    @Binding var text: String
    var lines: ClosedRange<Int> = 1...1
    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(SC.text).lineLimit(lines)
            .padding(10).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SC.lineStrong))
    }
}

func openPanel(_ types: [UTType], _ done: (URL) -> Void) {
    let p = NSOpenPanel()
    p.allowedContentTypes = types
    p.allowsMultipleSelection = false
    if p.runModal() == .OK, let u = p.url { done(u) }
}

private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
private func secs(_ v: Double) -> String { v <= 0.001 ? "Off" : String(format: "%.1f s", v) }

// MARK: - Edit

struct EditPanel: View {
    @ObservedObject var ed: ReelEditor
    @State private var showKeys = false
    var body: some View {
        HStack(alignment: .top) {
            PanelTitle(title: "Edit", subtitle: "Click a clip, or drag across the timeline to pick a stretch.", icon: "scissors")
            Spacer()
            IconButton(icon: "keyboard", help: "Keyboard shortcuts") { showKeys = true }
                .popover(isPresented: $showKeys, arrowEdge: .bottom) { ShortcutsCard().padding(14).frame(width: 300).background(SC.panel).presentationBackground(SC.panel) }
        }
        if ed.selection == .range, let r = ed.range {
            RangeCard(ed: ed, range: r).transition(.scale(scale: 0.97).combined(with: .opacity))
        } else if let (_, clip) = ed.selectedClip {
            ClipSection(ed: ed, clip: clip).transition(.scale(scale: 0.97).combined(with: .opacity))
        } else {
            PickHint()
        }
        PanelSection(title: "Pauses") {
            Chips(options: [(0, "Keep"), (1, "Tight"), (2, "Sharp"), (3, "Relaxed")],
                  selection: Binding(get: { ed.plan.maxPause.map { $0 <= 0 ? 0 : $0 <= 0.15 ? 1 : $0 <= 0.3 ? 2 : 3 } ?? 0 },
                                     set: { v in ed.change { $0.maxPause = [0, 0.12, 0.25, 0.5][v] } }))
            Text("Silences in your speech are trimmed to this. They show as fine marks inside a clip.").font(.system(size: 11.5)).foregroundStyle(SC.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        CleanUpCard(ed: ed)
        PanelSection(title: "Whole video speed") {
            Chips(options: [(1.0, "1×"), (1.1, "1.1×"), (1.25, "1.25×"), (1.5, "1.5×"), (2.0, "2×")], selection: ed.bind(\.speed))
            HStack(spacing: 6) {
                stat("Original", clock(ed.originalLength))
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(SC.faint)
                stat("Now", clock(ed.editedLength))
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(SC.text)
            Text(label).font(.system(size: 10.5)).foregroundStyle(SC.dim)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(SC.wash(0.05)))
    }
}

/// Filler words, repeated words and retakes, each one click away.
struct CleanUpCard: View {
    @ObservedObject var ed: ReelEditor
    var body: some View {
        PanelSection(title: "Clean up") {
            let fillers = ed.fillerWords.count, repeats = ed.repeats.count
            fix("wand.and.stars", fillers == 0 ? "No filler words" : "\(fillers) filler word\(fillers == 1 ? "" : "s")", "Um, uh, er, hmm", fillers > 0) { ed.removeFillers() }
            fix("repeat", repeats == 0 ? "No repeats" : "\(repeats) repeat\(repeats == 1 ? "" : "s")", "Words said twice and retakes; keeps the last go", repeats > 0) { ed.removeRepeats() }
            Button {
                ed.change { $0.removed = []; $0.kept = []; $0.splits = [] }
            } label: {
                Label("Bring back everything I cut", systemImage: "arrow.counterclockwise").font(.system(size: 11.5, weight: .medium)).foregroundStyle(SC.dim)
            }
            .buttonStyle(.plain)
            .disabled(ed.plan.removed.isEmpty && ed.plan.kept.isEmpty && ed.plan.splits.isEmpty)
        }
    }
    private func fix(_ icon: String, _ title: String, _ detail: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? AnyShapeStyle(SC.gradient) : AnyShapeStyle(SC.faint)).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(on ? SC.text : SC.dim)
                Text(detail).font(.system(size: 11)).foregroundStyle(SC.faint)
            }
            Spacer()
            if on {
                Button(action: action) {
                    Text("Remove").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 11).frame(height: 26).background(Capsule().fill(SC.gradient)).glow(true, radius: 5)
                }
                .buttonStyle(Springy())
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green.opacity(0.8))
            }
        }
    }
}

/// What to do when nothing's picked.
struct PickHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            hint("cursorarrow.click", "Click the video on the timeline", "picks a clip to trim, split, speed up or mute")
            hint("arrow.left.and.right.square", "Press and drag across it", "picks just that stretch to cut, keep or speed up")
            hint("scissors", "Press S", "splits the video at the playhead")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioCard(16)
    }
    private func hint(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(SC.gradient).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(SC.text)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(SC.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A small square action: icon over a word.
struct ActionTile: View {
    let title: String
    let icon: String
    var danger = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(danger ? Color(nsColor: .systemRed) : SC.text)
            .opacity(enabled ? 1 : 0.4)
            .frame(maxWidth: .infinity).frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(SC.wash(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(SC.line))
        }
        .buttonStyle(Springy())
    }
}

/// The header of a picked clip or stretch.
private func pickHeader(_ icon: String, _ title: String, _ span: TimeSpan) -> some View {
    HStack(spacing: 8) {
        Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SC.gradient))
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(SC.text)
            Text("\(clock(span.start)) – \(clock(span.end))").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(SC.dim)
        }
        Spacer()
        Text(String(format: "%.1f s", span.length)).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(SC.text)
            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(SC.wash(0.08)))
    }
}

private let speedChoices: [(Double, String)] = [(0.5, "0.5×"), (1.0, "1×"), (1.5, "1.5×"), (2.0, "2×"), (4.0, "4×")]

struct ClipSection: View {
    @ObservedObject var ed: ReelEditor
    let clip: Clip
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            pickHeader("film", "Clip", clip.out)
            HStack(spacing: 6) {
                ActionTile(title: "Split", icon: "scissors") { ed.split() }
                ActionTile(title: clip.volume == 0 ? "Unmute" : "Mute", icon: clip.volume == 0 ? "speaker.wave.2" : "speaker.slash") {
                    ed.beginChange(); ed.setClip(volume: clip.volume == 0 ? 1 : 0, for: clip)
                }
                ActionTile(title: "Delete", icon: "trash", danger: true) { ed.deleteSelection() }
            }
            row("Speed") {
                Chips(options: speedChoices, selection: Binding(get: { (ed.clipSpeed(clip) * 100).rounded() / 100 }, set: { v in ed.beginChange(); ed.setClip(speed: v, for: clip) }))
            }
            ValueSlider(label: "Volume", value: Binding(get: { clip.volume }, set: { ed.setClip(volume: $0, for: clip) }), range: 0...2,
                        format: { "\(Int(($0 * 100).rounded()))%" }, reset: 1, onBegin: ed.beginChange)
            if ed.audioTracks > 1 {
                ClipMix(ed: ed, mic: clip.mic, sys: clip.sys) { mic, sys in ed.setClip(mic: mic, sys: sys, for: clip) }
            }
        }
        .padding(14)
        .studioCard(16)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SC.gradient, lineWidth: 1.4).opacity(0.75))
    }
}

struct RangeCard: View {
    @ObservedObject var ed: ReelEditor
    let range: TimeSpan
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            pickHeader("arrow.left.and.right", "Picked stretch", range)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ActionTile(title: "Cut it", icon: "scissors", danger: true) { ed.deleteSelection() }
                ActionTile(title: "Keep only", icon: "arrow.down.right.and.arrow.up.left") { ed.keepOnlyRange() }
                ActionTile(title: "Make a clip", icon: "rectangle.split.3x1") { ed.splitRange() }
                ActionTile(title: "Mute", icon: "speaker.slash") { ed.beginChange(); ed.setRange(volume: 0) }
                ActionTile(title: "Zoom in", icon: "plus.magnifyingglass") { ed.zoomOnRange() }
                ActionTile(title: "Add text", icon: "textformat") { ed.textOnRange() }
            }
            row("Speed") {
                Chips(options: speedChoices, selection: Binding(get: { 1.0 }, set: { v in ed.beginChange(); ed.setRange(speed: v) }))
            }
            if ed.audioTracks > 1 {
                let p = ed.timeline.index(at: (range.start + range.end) / 2).map { ed.timeline.pieces[$0] }
                ClipMix(ed: ed, mic: p?.mic ?? 1, sys: p?.sys ?? 1) { mic, sys in ed.setRange(mic: mic, sys: sys) }
            }
            Text("Drag the white ends on the timeline to adjust the stretch. Esc lets go of it.").font(.system(size: 11)).foregroundStyle(SC.faint)
        }
        .padding(14)
        .studioCard(16)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SC.gradient, lineWidth: 1.4).opacity(0.75))
    }
}

private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(label).font(.system(size: 12.5)).foregroundStyle(SC.text)
        content()
    }
}

struct ShortcutsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Keyboard shortcuts").font(.system(size: 13, weight: .bold)).foregroundStyle(SC.text).padding(.bottom, 3)
            line("Space", "Play or pause")
            line("← →", "Back or forward 5 seconds")
            line("⇧← ⇧→", "One frame")
            line("S", "Split at the playhead")
            line("⌫", "Delete or cut what's picked")
            line("⌘A", "Pick the whole video")
            line("T  /  Z", "Add text  /  add a zoom")
            line("⌘D", "Duplicate")
            line("⌘Z  ⇧⌘Z", "Undo, redo")
            line("Esc", "Let go of what's picked")
        }
    }
    private func line(_ k: String, _ what: String) -> some View {
        HStack {
            Text(k).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(SC.text).frame(width: 86, alignment: .leading)
            Text(what).font(.system(size: 12)).foregroundStyle(SC.dim)
        }
    }
}

// MARK: - Text

struct TextPanel: View {
    @ObservedObject var ed: ReelEditor
    var body: some View {
        PanelTitle(title: "Text", subtitle: "Add a style, then type. Drag it on the preview to place it and on the timeline to time it.", icon: "textformat")
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(ReelEditor.textPresets, id: \.name) { p in PresetTile(name: p.name, item: p.item) { ed.addText(p.item) } }
        }
        if case .text(let id) = ed.selection, let item = ed.plan.texts.first(where: { $0.id == id }) {
            TextInspector(ed: ed, item: item)
        } else if !ed.plan.texts.isEmpty {
            PanelSection(title: "On this video") {
                ForEach(ed.plan.texts) { t in
                    LayerRow(icon: "textformat", title: t.text, time: ed.timeline.outputSpan(of: TimeSpan(start: t.start, end: t.end))?.start) {
                        ed.select(.text(t.id))
                        if let s = ed.timeline.outputSpan(of: TimeSpan(start: t.start, end: t.end)) { ed.seek(s.start) }
                    }
                }
            }
        }
    }
}

struct PresetTile: View {
    let name: String
    let item: TextItem
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                    sample
                }
                .frame(height: 54)
                Text(name).font(.system(size: 11.5, weight: .medium))
            }
            .padding(6)
            .studioCard(14, fill: hover ? SC.hover : SC.card)
        }
        .buttonStyle(Springy()).onHover { hover = $0 }
    }

    @ViewBuilder private var sample: some View {
        let size = min(22, max(10, item.size * 180))
        let font = Font(StudioType.font(item.font, size: size, weight: item.weight))
        let t = Text(name == "Big number" ? "10×" : name == "Typewriter" ? "Typing…" : name).font(font).foregroundStyle(Color(nsColor: NSColor(hex: item.color)))
        if item.style == "box" {
            t.padding(.horizontal, 7).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: NSColor(hex: item.boxColor))))
        } else {
            t.shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        }
    }
}

struct LayerRow: View {
    let icon: String
    let title: String
    let time: Double?
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(SC.dim).frame(width: 16)
                Text(title.isEmpty ? "Untitled" : title).font(.system(size: 12.5)).lineLimit(1)
                Spacer()
                Text(time.map(clock) ?? "cut").font(.system(size: 11, design: .monospaced)).foregroundStyle(SC.dim)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? SC.hover : SC.wash(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

struct TextInspector: View {
    @ObservedObject var ed: ReelEditor
    let item: TextItem
    @FocusState private var typing: Bool
    var body: some View {
        let id = item.id
        PanelSection(title: "Text", trailing: AnyView(HStack(spacing: 0) {
            IconButton(icon: "plus.square.on.square", help: "Duplicate (⌘D)", size: 11.5) { ed.duplicateSelection() }
            IconButton(icon: "trash", help: "Delete (⌫)", size: 11.5) { ed.deleteSelection() }
        })) {
            StudioField(placeholder: "Type here", text: ed.bindText(id, \.text, undoable: false), lines: 1...5)
                .focused($typing)
                .onChange(of: typing) { if typing { ed.beginChange() } }
            Chips(options: StudioType.families.map { ($0.0, $0.1) }, selection: ed.bindText(id, \.font), columns: 3)
            Chips(options: [("regular", "Regular"), ("medium", "Medium"), ("bold", "Bold"), ("heavy", "Heavy")], selection: ed.bindText(id, \.weight))
            ValueSlider(label: "Size", value: ed.bindText(id, \.size, undoable: false), range: 0.025...0.25, format: { "\(Int($0 * 1000))" }, reset: 0.075, onBegin: ed.beginChange)
            Swatches(hex: ed.bindText(id, \.color))
        }
        PanelSection(title: "Style") {
            Chips(options: [("plain", "Plain"), ("shadow", "Shadow"), ("outline", "Outline"), ("box", "Box")], selection: ed.bindText(id, \.style))
            if item.style == "box" { Swatches(hex: ed.bindText(id, \.boxColor)) }
            Text("Animation").font(.system(size: 12.5))
            Chips(options: [("none", "None"), ("fade", "Fade"), ("pop", "Pop"), ("slide", "Slide"), ("typewriter", "Type")], selection: ed.bindText(id, \.animation))
        }
        PanelSection(title: "Place and time") {
            HStack(alignment: .top) {
                PositionGrid(x: item.x, y: item.y) { x, y in ed.change { p in if let i = p.texts.firstIndex(where: { $0.id == id }) { p.texts[i].x = x; p.texts[i].y = y } } }
                Spacer()
                Text("Or drag it on the preview.").font(.system(size: 11.5)).foregroundStyle(SC.dim).frame(width: 110, alignment: .leading)
            }
            TimingRow(ed: ed, sel: .text(id), start: item.start, end: item.end)
        }
    }
}

// MARK: - Subtitles

struct CaptionsPanel: View {
    @ObservedObject var ed: ReelEditor
    var body: some View {
        PanelTitle(title: "Subtitles", subtitle: "Written from what you say. Pick a style, then fix any word below.", icon: "captions.bubble")
        PanelSection(title: "Show", trailing: AnyView(Toggle("", isOn: ed.bind(\.captions)).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(SC.accent))) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(Captions.presets, id: \.0) { p in
                    CaptionTile(preset: p.0, name: p.1, style: ed.plan.captionStyle, selected: ed.plan.captionStyle.preset == p.0) {
                        ed.change { $0.captionStyle.preset = p.0; $0.captions = true }
                    }
                }
            }
            Text("Position").font(.system(size: 12.5))
            Chips(options: [("top", "Top"), ("middle", "Middle"), ("bottom", "Bottom")], selection: ed.bind(\.captionPosition))
            ValueSlider(label: "Size", value: ed.bind(\.captionStyle.size, undoable: false), range: 0.6...1.8, format: pct, reset: 1, onBegin: ed.beginChange)
            Stepper(value: ed.bind(\.captionStyle.wordsPerCue), in: 1...6) {
                Text("\(ed.plan.captionStyle.wordsPerCue) word\(ed.plan.captionStyle.wordsPerCue == 1 ? "" : "s") at a time").font(.system(size: 12.5))
            }
            Toggle("Capitals", isOn: ed.bind(\.captionStyle.uppercase)).toggleStyle(.checkbox).font(.system(size: 12.5))
            Chips(options: StudioType.families.map { ($0.0, $0.1) }, selection: ed.bind(\.captionStyle.font), columns: 3)
            Text("Text").font(.system(size: 12.5))
            Swatches(hex: ed.bind(\.captionStyle.color))
            if ["karaoke", "highlight"].contains(ed.plan.captionStyle.preset) {
                Text("Word being said").font(.system(size: 12.5))
                Swatches(hex: ed.bind(\.captionStyle.accent))
            }
        }
        if !ed.whisperReady { WhisperCard(ed: ed) }
        if ed.whisperReady {
            PanelSection(title: "Language spoken") {
                SwiftUI.Picker("", selection: Binding(get: { Settings.speechLanguage }, set: { Settings.speechLanguage = $0; Task { await ed.transcribe() } })) {
                    ForEach(Whisper.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().disabled(ed.transcribing != nil)
                Button(ed.transcribing != nil ? "Listening again…" : "Write the words again") { Task { await ed.transcribe() } }
                    .controlSize(.small).disabled(ed.transcribing != nil)
            }
        }
        CueList(ed: ed)
    }
}

struct CaptionTile: View {
    let preset: String
    let name: String
    let style: CaptionStyle
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.16))
                    sample
                }
                .frame(height: 40)
                Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(selected ? SC.text : SC.dim)
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? SC.hover : SC.wash(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? AnyShapeStyle(SC.gradient) : AnyShapeStyle(SC.line), lineWidth: selected ? 1.5 : 1))
            .glow(selected, radius: 8)
        }
        .buttonStyle(Springy())
    }

    @ViewBuilder private var sample: some View {
        let accent = Color(nsColor: NSColor(hex: style.accent))
        let f = Font.system(size: 12.5, weight: .heavy)
        switch preset {
        case "karaoke": (Text("Say it ").foregroundColor(.white) + Text("loud").foregroundColor(accent)).font(f)
        case "highlight":
            HStack(spacing: 3) {
                Text("Say it").font(f).foregroundStyle(.white)
                Text("loud").font(f).foregroundStyle(.black).padding(.horizontal, 3).background(RoundedRectangle(cornerRadius: 3).fill(accent))
            }
        case "box": Text("Say it loud").font(f).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.8)))
        case "minimal": Text("Say it loud").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).shadow(radius: 2)
        default: Text("Say it loud").font(f).foregroundStyle(.white).shadow(color: .black, radius: 0.5).shadow(color: .black, radius: 1.5)
        }
    }
}

struct CueList: View {
    @ObservedObject var ed: ReelEditor
    var body: some View {
        PanelSection(title: "Captions", trailing: ed.plan.words == nil ? nil : AnyView(Button("Undo fixes") { ed.change { $0.words = nil } }
            .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(SC.dim))) {
            if ed.cues.isEmpty {
                Text(ed.transcribing != nil ? "Writing captions…" : "No speech found yet.").font(.system(size: 12)).foregroundStyle(SC.dim)
            }
            LazyVStack(spacing: 2) {
                ForEach(Array(ed.cues.enumerated()), id: \.offset) { _, cue in
                    CueRow(ed: ed, cue: cue, current: ed.time >= cue.start && ed.time < cue.end)
                }
            }
        }
    }
}

struct CueRow: View {
    @ObservedObject var ed: ReelEditor
    let cue: Cue
    let current: Bool
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Text(clock(cue.start)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(current ? SC.accent : SC.dim)
                .frame(width: 48, alignment: .leading)
                .onTapGesture { ed.seek(cue.start + 0.01) }
            TextField("", text: $text).textFieldStyle(.plain).font(.system(size: 12.5))
                .focused($focused)
                .onSubmit { ed.editCue(cue, text: text) }
                .onChange(of: focused) { if !focused, text != cue.text { ed.editCue(cue, text: text) } }
        }
        .padding(.horizontal, 6).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(current ? SC.accent.opacity(0.12) : .clear))
        .onAppear { text = cue.text }
        .onChange(of: cue.text) { text = cue.text }
    }
}

/// Sets up accurate captions: the whisper-cli tool, then the model.
struct WhisperCard: View {
    @ObservedObject var ed: ReelEditor
    var body: some View {
        PanelSection(title: "More accurate captions") {
            Text("Captions now use Apple's basic recognition, which gets a lot wrong. Whisper is free, far more accurate and runs on your Mac.")
                .font(.system(size: 12)).foregroundStyle(SC.dim).fixedSize(horizontal: false, vertical: true)
            if Whisper.binary == nil {
                HStack(spacing: 8) {
                    Text("1. In Terminal: brew install whisper-cpp").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("Copy") { copy("brew install whisper-cpp") }.controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                if let p = ed.modelDownload {
                    ProgressView(value: p).frame(maxWidth: .infinity)
                    Text("\(Int(p * 100))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(SC.dim)
                } else if !Whisper.hasModel {
                    Text("\(Whisper.binary == nil ? "2." : "1.") Get the model (\(Whisper.modelSize))").font(.system(size: 12))
                    Spacer()
                    Button("Download") { ed.downloadModel() }.controlSize(.small)
                } else {
                    Text("Model downloaded.").font(.system(size: 12)).foregroundStyle(SC.dim)
                    Spacer()
                    Button("Check again") { ed.checkWhisper() }.controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Transcript

struct TranscriptPanel: View {
    @ObservedObject var ed: ReelEditor
    @AppStorage("transcriptMode") private var mode = "fix"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(title: "Transcript", subtitle: mode == "fix"
                       ? "Type to fix any word. The captions change as you type."
                       : "Edit the video like a document: select words and press Delete to cut them. Click a crossed out word to bring it back.",
                       icon: "text.alignleft")
            Chips(options: [("fix", "Fix words"), ("cut", "Cut video")], selection: $mode)
            if mode == "cut" {
                let fillers = ed.fillerWords.count
                WideButton(title: fillers == 0 ? "No filler words" : "Cut \(fillers) filler word\(fillers == 1 ? "" : "s")", icon: "wand.and.stars", primary: fillers > 0) { ed.removeFillers() }
                    .disabled(fillers == 0)
            } else if ed.plan.words != nil {
                Button { ed.change { $0.words = nil } } label: {
                    Label("Go back to what Mercury heard", systemImage: "arrow.counterclockwise").font(.system(size: 11.5, weight: .medium)).foregroundStyle(SC.dim)
                }
                .buttonStyle(.plain)
            }
            if ed.words.isEmpty {
                Text(ed.transcribing != nil ? "Writing the transcript…" : "No speech found yet.").font(.system(size: 12.5)).foregroundStyle(SC.dim)
                Spacer()
            } else {
                TranscriptView(ed: ed, editable: mode == "fix")
                    .studioCard(14)
            }
        }
        .padding(16)
    }
}

final class TranscriptTextView: NSTextView {
    var ranges: [NSRange] = []
    var cutting = false
    var onDelete: ((Range<Int>) -> Void)?
    var onClick: ((Int) -> Void)?

    func words(in r: NSRange) -> Range<Int>? {
        let hit = ranges.indices.filter { NSIntersectionRange(ranges[$0], r).length > 0 }
        guard let a = hit.first, let b = hit.last else { return nil }
        return a..<(b + 1)
    }

    override func keyDown(with e: NSEvent) {
        if cutting, [51, 117].contains(e.keyCode), selectedRange().length > 0, let w = words(in: selectedRange()) { onDelete?(w); return }
        super.keyDown(with: e)
    }

    override func mouseDown(with e: NSEvent) {
        super.mouseDown(with: e)  // tracks the drag until the button comes up
        guard cutting else { return }
        let sel = selectedRange()
        guard sel.length == 0, let i = ranges.firstIndex(where: { NSLocationInRange(sel.location, $0) || sel.location == NSMaxRange($0) }) else { return }
        onClick?(i)
    }

    /// Where each word sits in the text as it is now.
    func measure() {
        var out: [NSRange] = []
        let ns = string as NSString
        var i = 0
        while i < ns.length {
            while i < ns.length, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: i)) ?? " ") { i += 1 }
            let start = i
            while i < ns.length, !CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: i)) ?? " ") { i += 1 }
            if i > start { out.append(NSRange(location: start, length: i - start)) }
        }
        ranges = out
    }
}

struct TranscriptView: NSViewRepresentable {
    @ObservedObject var ed: ReelEditor
    let editable: Bool

    final class Coordinator: NSObject, NSTextViewDelegate {
        var signature = ""
        var current = -1
        var dirty = false
        var commit: DispatchWorkItem?
        var apply: (([String]) -> Void)?

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? TranscriptTextView else { return }
            dirty = true
            commit?.cancel()
            let work = DispatchWorkItem { [weak self, weak tv] in
                guard let self, let tv else { return }
                self.dirty = false
                tv.measure()
                self.apply?(tv.string.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init))
            }
            commit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
        func textDidEndEditing(_ n: Notification) { if dirty, let c = commit { c.cancel(); c.perform() } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = TranscriptTextView(frame: .zero)
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = context.coordinator
        tv.insertionPointColor = SC.nsAccent
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? TranscriptTextView else { return }
        let ed = self.ed
        let c = context.coordinator
        let words = ed.words
        tv.isEditable = editable
        tv.cutting = !editable
        c.apply = { tokens in ed.applyTranscript(tokens) }
        tv.onDelete = { r in ed.cutWords(r) }
        tv.onClick = { i in
            let w = ed.words[i]
            if ed.isCut(w) {
                // Bring back the whole run of crossed out words around it.
                var a = i, b = i
                while a > 0, ed.isCut(ed.words[a - 1]) { a -= 1 }
                while b + 1 < ed.words.count, ed.isCut(ed.words[b + 1]) { b += 1 }
                ed.restoreWords(a..<(b + 1))
            } else if let t = ed.timeline.output(at: w.start + 0.01) {
                ed.seek(t)
            }
        }
        let cut = words.map { ed.isCut($0) }
        let sig = "\(editable)-\(words.count)-\(words.map(\.text).joined(separator: " ").hashValue)-\(cut.hashValue)-\(SC.dark)"
        // While you're typing, or when the words already match what's on screen, leave the text alone.
        let typing = editable && (c.dirty || (tv.window?.firstResponder === tv && tv.ranges.count == words.count
                                               && tv.string.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init) == words.map(\.text)))
        if sig != c.signature && !typing {
            c.signature = sig
            c.current = -1
            let text = NSMutableAttributedString()
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 5
            para.paragraphSpacing = 12
            let ink = SC.dark ? NSColor.white.withAlphaComponent(0.92) : NSColor(hex: "16171B")
            let normal: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: ink, .paragraphStyle: para]
            for (i, w) in words.enumerated() {
                if i > 0 { text.append(NSAttributedString(string: w.start - words[i - 1].end > 1.6 ? "\n" : " ", attributes: normal)) }
                var a = normal
                if cut[i] {
                    a[.foregroundColor] = ink.withAlphaComponent(0.35)
                    a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                text.append(NSAttributedString(string: w.text, attributes: a))
            }
            let sel = tv.selectedRange()
            tv.textStorage?.setAttributedString(text)
            tv.typingAttributes = normal
            if NSMaxRange(sel) <= text.length { tv.setSelectedRange(sel) }
            tv.measure()
        } else if sig != c.signature {
            c.signature = sig
        }
        // The word being said.
        guard tv.ranges.count == words.count, !c.dirty else { return }
        let s = ed.timeline.source(at: ed.time)
        let now = words.lastIndex { $0.start <= s + 0.02 } ?? -1
        if now != c.current, let store = tv.textStorage {
            let old = c.current
            if old >= 0, old < tv.ranges.count, NSMaxRange(tv.ranges[old]) <= store.length { store.removeAttribute(.backgroundColor, range: tv.ranges[old]) }
            if now >= 0, now < tv.ranges.count, NSMaxRange(tv.ranges[now]) <= store.length {
                store.addAttribute(.backgroundColor, value: SC.nsAccent.withAlphaComponent(0.3), range: tv.ranges[now])
                if ed.playing { tv.scrollRangeToVisible(tv.ranges[now]) }
            }
            c.current = now
        }
    }
}

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

enum StudioFrames {
    static func frame(_ url: URL, at s: Double) async -> CGImage? {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.maximumSize = CGSize(width: 640, height: 640)
        g.appliesPreferredTrackTransform = true
        return try? await g.image(at: CMTime(seconds: s, preferredTimescale: 600)).image
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

// MARK: - Canvas

struct CanvasPanel: View {
    @ObservedObject var ed: ReelEditor
    var body: some View {
        PanelTitle(title: "Canvas", subtitle: "The shape of the video and what's around the recording.", icon: "aspectratio")
        PanelSection(title: "Shape") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(ReelSize.allCases) { s in
                    Button { ed.size = s } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(s.ratio, systemImage: s.icon).font(.system(size: 12.5, weight: .semibold))
                            Text(s.use).font(.system(size: 10.5)).foregroundStyle(ed.size == s ? Color.white.opacity(0.8) : SC.dim).lineLimit(1)
                        }
                        .foregroundStyle(ed.size == s ? Color.white : SC.text)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(ed.size == s ? AnyShapeStyle(SC.gradient) : AnyShapeStyle(SC.wash(0.05))))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(ed.size == s ? Color.white.opacity(0.2) : SC.line))
                        .glow(ed.size == s, radius: 8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        PanelSection(title: "Layout") {
            Chips(options: [("fit", "Fit"), ("fill", "Fill"), ("framed", "Framed")], selection: ed.bind(\.canvas.layout))
            Text(ed.plan.canvas.layout == "fit" ? "The whole recording, with the background around it." :
                 ed.plan.canvas.layout == "fill" ? "Fills the frame; the edges are cropped." : "A floating window with rounded corners and a shadow.")
                .font(.system(size: 11.5)).foregroundStyle(SC.dim)
            if ed.plan.canvas.layout == "framed" {
                ValueSlider(label: "Padding", value: ed.bind(\.canvas.padding, undoable: false), range: 0...0.2, format: pct, reset: 0.06, onBegin: ed.beginChange)
                ValueSlider(label: "Corners", value: ed.bind(\.canvas.corner, undoable: false), range: 0...0.08, format: { "\(Int($0 * 1000))" }, reset: 0.03, onBegin: ed.beginChange)
            } else if ed.size != .original {
                ValueSlider(label: "Crop in", value: ed.bind(\.zoom, undoable: false), range: 1...3, format: { String(format: "%.2f×", $0) }, reset: 1, onBegin: ed.beginChange)
                if ed.plan.zoom > 1.01 || ed.plan.canvas.layout == "fill" {
                    ValueSlider(label: "Left ↔ right", value: ed.bind(\.focusX, undoable: false), range: 0...1, format: pct, reset: 0.5, onBegin: ed.beginChange)
                    ValueSlider(label: "Top ↕ bottom", value: ed.bind(\.focusY, undoable: false), range: 0...1, format: pct, reset: 0.5, onBegin: ed.beginChange)
                }
            }
        }
        PanelSection(title: "Background") {
            Chips(options: [("blur", "Blur"), ("color", "Colour"), ("gradient", "Gradient")], selection: ed.bind(\.canvas.background))
            if ed.plan.canvas.background != "blur" {
                Swatches(hex: ed.bind(\.canvas.color), colors: ["15151A", "FFFFFF", "F4F1EA", "1C2541", "0B3D2E", "3A0CA3", "FF6B35", "E63946", "2A9D8F", "FFB703"])
            }
            if ed.plan.canvas.background == "gradient" {
                Swatches(hex: ed.bind(\.canvas.color2), colors: ["5B4BDB", "FF6FB5", "00B4D8", "FFD60A", "30D158", "FF453A", "111111", "FFFFFF", "8338EC", "FB5607"])
            }
        }
    }
}

// MARK: - Colour

struct ColourPanel: View {
    @ObservedObject var ed: ReelEditor
    var body: some View {
        PanelTitle(title: "Colour", subtitle: "Make it pop, or fix a dull camera.", icon: "camera.filters")
        PanelSection(title: "Looks") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5) {
                look("Natural") { $0 = Look(fadeIn: $0.fadeIn, fadeOut: $0.fadeOut) }
                look("Vivid") { $0.saturation = 1.35; $0.contrast = 1.08; $0.warmth = 0; $0.brightness = 0; $0.vignette = 0 }
                look("Punchy") { $0.saturation = 1.15; $0.contrast = 1.2; $0.vignette = 0.35; $0.warmth = 0; $0.brightness = 0 }
                look("Warm") { $0.warmth = 0.4; $0.saturation = 1.1; $0.contrast = 1.02; $0.brightness = 0; $0.vignette = 0 }
                look("Cool") { $0.warmth = -0.4; $0.saturation = 1.05; $0.contrast = 1.04; $0.brightness = 0; $0.vignette = 0 }
                look("Mono") { $0.saturation = 0; $0.contrast = 1.12; $0.warmth = 0; $0.brightness = 0; $0.vignette = 0.2 }
            }
        }
        PanelSection(title: "Filters") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(StudioFilters.all, id: \.0) { f in
                    FilterTile(ed: ed, id: f.0, name: f.1)
                }
            }
        }
        PanelSection(title: "Adjust") {
            ValueSlider(label: "Brightness", value: ed.bind(\.look.brightness, undoable: false), range: -1...1, format: signed, reset: 0, onBegin: ed.beginChange)
            ValueSlider(label: "Contrast", value: ed.bind(\.look.contrast, undoable: false), range: 0.5...1.5, format: around1, reset: 1, onBegin: ed.beginChange)
            ValueSlider(label: "Saturation", value: ed.bind(\.look.saturation, undoable: false), range: 0...2, format: around1, reset: 1, onBegin: ed.beginChange)
            ValueSlider(label: "Warmth", value: ed.bind(\.look.warmth, undoable: false), range: -1...1, format: signed, reset: 0, onBegin: ed.beginChange)
            ValueSlider(label: "Vignette", value: ed.bind(\.look.vignette, undoable: false), range: 0...1, format: pct, reset: 0, onBegin: ed.beginChange)
        }
        PanelSection(title: "Start and end") {
            ValueSlider(label: "Fade from black", value: ed.bind(\.look.fadeIn, undoable: false), range: 0...3, format: secs, reset: 0, onBegin: ed.beginChange)
            ValueSlider(label: "Fade to black", value: ed.bind(\.look.fadeOut, undoable: false), range: 0...3, format: secs, reset: 0, onBegin: ed.beginChange)
        }
    }

    private func look(_ name: String, _ f: @escaping (inout Look) -> Void) -> some View {
        Button { ed.change { f(&$0.look) } } label: {
            Text(name).font(.system(size: 11.5, weight: .medium)).frame(maxWidth: .infinity).frame(height: 28)
                .foregroundStyle(SC.text)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SC.wash(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SC.line))
        }
        .buttonStyle(Springy())
    }
    private func signed(_ v: Double) -> String { String(format: "%+d", Int((v * 100).rounded())) }
    private func around1(_ v: Double) -> String { String(format: "%+d", Int(((v - 1) * 100).rounded())) }
}

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

/// A filter choice with a little preview of the recording through it.
struct FilterTile: View {
    @ObservedObject var ed: ReelEditor
    let id: String
    let name: String
    @State private var thumb: CGImage?
    var body: some View {
        let on = ed.plan.look.filter == id
        Button { ed.change { $0.look.filter = id } } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SC.wash(0.08))
                    if let thumb { Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                }
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(on ? AnyShapeStyle(SC.gradient) : AnyShapeStyle(SC.line), lineWidth: on ? 2 : 1))
                .glow(on, radius: 6)
                Text(name).font(.system(size: 10.5, weight: on ? .semibold : .medium)).foregroundStyle(on ? SC.text : SC.dim)
            }
        }
        .buttonStyle(Springy())
        .task {
            guard let frame = await StudioFrames.frame(ed.url, at: min(10, ed.originalLength / 2)) else { return }
            let img = StudioFilters.apply(id, to: CIImage(cgImage: frame))
            thumb = CIContext().createCGImage(img, from: CIImage(cgImage: frame).extent)
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

/// One clip's mix of the two sound tracks: quick choices, then a slider for each.
struct ClipMix: View {
    @ObservedObject var ed: ReelEditor
    let mic: Double
    let sys: Double
    /// Sets (mic, computer); nil leaves that one as it is.
    let set: (Double?, Double?) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sound mix").font(.system(size: 12.5)).foregroundStyle(SC.text)
            Chips(options: [(0, "Both"), (1, "Mic only"), (2, "Computer only")], selection: Binding(
                get: { mic > 0.001 && sys < 0.001 ? 1 : mic < 0.001 && sys > 0.001 ? 2 : 0 },
                set: { v in ed.beginChange(); set(v == 2 ? 0 : 1, v == 1 ? 0 : 1) }))
            track("mic.fill", "Your mic", mic) { set($0, nil) }
            track("speaker.wave.2.fill", "Computer sound", sys) { set(nil, $0) }
        }
    }

    private func track(_ icon: String, _ label: String, _ value: Double, _ change: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(value < 0.001 ? AnyShapeStyle(SC.faint) : AnyShapeStyle(SC.gradient))
                Text(label).font(.system(size: 12)).foregroundStyle(SC.text)
                Spacer()
                Text(value < 0.001 ? "Off" : "\(Int((value * 100).rounded()))%").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(SC.dim)
                    .onTapGesture(count: 2) { ed.beginChange(); change(1) }
                    .help("Double-click to reset")
            }
            StudioSlider(value: Binding(get: { value }, set: change), range: 0...1.5, onBegin: ed.beginChange)
        }
    }
}
