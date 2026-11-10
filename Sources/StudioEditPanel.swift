// The editor's Edit panel: cleaning up pauses and filler words, and trimming, splitting and speeding up
// the clip or range you've picked on the timeline.

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

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
