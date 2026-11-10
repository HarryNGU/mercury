// The editor's tool panels, down the left beside the rail: Edit, Text, Subtitles, Transcript, Zoom,
// Media, Audio, Canvas, Colour and Claude. Picking something on the timeline opens its panel.
//
// This file holds the panel switcher and the building blocks every panel shares. The panels themselves are in
// StudioEditPanel.swift, StudioTextPanels.swift, StudioMediaPanels.swift, StudioLookPanels.swift and
// StudioClaudePanel.swift.

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

func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
func secs(_ v: Double) -> String { v <= 0.001 ? "Off" : String(format: "%.1f s", v) }

enum StudioFrames {
    static func frame(_ url: URL, at s: Double) async -> CGImage? {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.maximumSize = CGSize(width: 640, height: 640)
        g.appliesPreferredTrackTransform = true
        return try? await g.image(at: CMTime(seconds: s, preferredTimescale: 600)).image
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
