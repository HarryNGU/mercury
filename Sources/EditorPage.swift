// The reel editor page: the stage with the player, the tool rail and panels, the timeline and the save bar.
// It shows what ReelEditor holds and sends your clicks back to it.

import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The editor page

struct EditorPage: View {
    let url: URL
    let onClose: () -> Void
    @StateObject private var ed: ReelEditor
    @State private var keys: Any?
    @State private var showExport = false
    @State private var showAdd = false
    @State private var dropping = false
    @AppStorage("studioTimelineHeight") private var timelineHeight = 236.0
    @AppStorage("studioTheme") private var theme = "auto"
    @Environment(\.colorScheme) private var macScheme
    @Namespace private var railPill
    @Namespace private var shapePill
    /// The open editor, for test runs.
    static weak var lastEditor: ReelEditor?

    init(url: URL, onClose: @escaping () -> Void) {
        self.url = url
        self.onClose = onClose
        _ed = StateObject(wrappedValue: ReelEditor(url: url))
    }

    private var dark: Bool { theme == "dark" || (theme == "auto" && macScheme == .dark) }

    var body: some View {
        SC.dark = dark
        // Changing the look redraws everything; the editor itself (and the keys) carry on.
        return content.id(dark)
            .onAppear {
                ed.start(); installKeys(); Self.lastEditor = ed
                // Don't start with the title box holding the keyboard, so Space plays straight away.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
            .onDisappear { ed.stop(); if let k = keys { NSEvent.removeMonitor(k); keys = nil } }
    }

    private var content: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                rail
                StudioPanel(ed: ed)
                    .frame(width: 318)
                    .background(SC.panel)
                    .overlay(alignment: .trailing) { Rectangle().fill(SC.line).frame(width: 1) }
                    .animation(.spring(response: 0.38, dampingFraction: 0.86), value: ed.tool)
                stage
            }
            timelineDivider
            StudioTimeline(ed: ed)
                .frame(height: max(timelineHeight, StudioTimeline.height(for: ed)))
        }
        .background(SC.bg)
        .environment(\.colorScheme, dark ? .dark : .light)
        .tint(SC.accent)
        .overlay { if dropping { dropZone } }
        .onDrop(of: [.fileURL], isTargeted: $dropping.animation(SC.spring)) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { u, _ in
                    if let u { DispatchQueue.main.async { ed.add(files: [u]) } }
                }
            }
            return true
        }
    }

    private var dropZone: some View {
        ZStack {
            Color.black.opacity(0.45)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(SC.gradient, style: StrokeStyle(lineWidth: 2.5, dash: [10, 8]))
                .padding(24)
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 38, weight: .semibold)).foregroundStyle(SC.gradient)
                Text("Drop to add").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(SC.text)
                Text("Videos go on top, pictures as overlays, songs as music.").font(.system(size: 13)).foregroundStyle(SC.dim)
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold)).foregroundStyle(SC.text)
                    .frame(width: 30, height: 30).background(Circle().fill(SC.wash(0.07)))
                    .overlay(Circle().strokeBorder(SC.line))
            }
            .buttonStyle(Springy()).help("Back to recordings")
            VStack(alignment: .leading, spacing: 1) {
                TextField("Title", text: Binding(get: { ed.plan.title }, set: { v in ed.plan.title = v }))
                    .textFieldStyle(.plain).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(SC.text).frame(maxWidth: 380)
                Text("\(clock(ed.editedLength)) · \(ed.size.ratio) · \(ed.timeline.clips.count) clip\(ed.timeline.clips.count == 1 ? "" : "s")")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(SC.faint)
            }
            Spacer()
            if let p = ed.transcribing { statusPill("Writing captions", p) }
            if let ex = ed.exporting { statusPill("Saving \(ex.size.ratio)", ex.progress) }
            Menu {
                SwiftUI.Picker("Look", selection: $theme) {
                    Label("Match my Mac", systemImage: "circle.lefthalf.filled").tag("auto")
                    Label("Light", systemImage: "sun.max").tag("light")
                    Label("Dark", systemImage: "moon").tag("dark")
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: dark ? "moon.fill" : "sun.max.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(SC.dim)
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Light or dark editor")
            HStack(spacing: 2) {
                IconButton(icon: "arrow.uturn.backward", help: "Undo (⌘Z)") { ed.undoLast() }.disabled(!ed.canUndo)
                IconButton(icon: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { ed.redoLast() }.disabled(!ed.canRedo)
            }
            .padding(3).background(Capsule().fill(SC.wash(0.05))).overlay(Capsule().strokeBorder(SC.line))
            GlowButton(title: ed.exporting == nil ? "Export" : "Saving…", icon: "square.and.arrow.up") { showExport = true }
                .disabled(ed.analysis == nil)
                .popover(isPresented: $showExport, arrowEdge: .bottom) { ExportSheet(ed: ed) }
        }
        .padding(.leading, 78).padding(.trailing, 16)   // room for the window's buttons
        .frame(height: 54)
        .background(SC.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(SC.line).frame(height: 1) }
    }

    private func statusPill(_ label: String, _ p: Double) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(SC.wash(0.12), lineWidth: 2.5)
                Circle().trim(from: 0, to: p).stroke(SC.gradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 15, height: 15)
            Text("\(label) \(Int(p * 100))%").font(.system(size: 11.5, weight: .medium)).foregroundStyle(SC.dim)
        }
        .padding(.horizontal, 11).frame(height: 28).background(Capsule().fill(SC.wash(0.05)))
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: Tools

    private var rail: some View {
        // Scrolls rather than making the window taller when it's short.
        ScrollView(showsIndicators: false) {
            VStack(spacing: 3) {
                Button { showAdd = true } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SC.gradient))
                            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.white.opacity(0.25)))
                            .shadow(color: SC.accent.opacity(0.55), radius: 10, y: 3)
                        Text("Add").font(.system(size: 10, weight: .semibold)).foregroundStyle(SC.text)
                    }
                    .frame(width: 62, height: 62)
                }
                .buttonStyle(Springy(hoverScale: 1.06))
                .help("Add text, zooms, videos, pictures or music")
                .popover(isPresented: $showAdd, arrowEdge: .trailing) { AddMenu(ed: ed) { showAdd = false } }
                Rectangle().fill(SC.line).frame(width: 34, height: 1).padding(.vertical, 6)
                ForEach(StudioTool.allCases) { t in
                    RailButton(tool: t, selected: ed.tool == t, pill: railPill) { withAnimation(SC.spring) { ed.tool = t } }
                }
            }
            .padding(.vertical, 10)
        }
        .frame(width: 74)
        .frame(maxHeight: .infinity)
        .background(SC.panel)
        .overlay(alignment: .trailing) { Rectangle().fill(SC.line).frame(width: 1) }
    }

    // MARK: Preview

    private var stage: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    ForEach(ReelSize.allCases) { s in
                        ShapeChip(size: s, selected: ed.size == s, pill: shapePill) { withAnimation(SC.spring) { ed.size = s } }
                    }
                }
                .padding(3).background(Capsule().fill(SC.wash(0.05))).overlay(Capsule().strokeBorder(SC.line))
                Spacer()
                if let e = ed.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(.orange).lineLimit(2)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(Color.orange.opacity(0.12)))
                        .onTapGesture { ed.error = nil }
                }
            }
            GeometryReader { geo in
                let fit = fitted(ed.aspect, in: geo.size)
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black)
                    if ed.analysis != nil {
                        PlayerView(player: ed.player)
                        StageOverlay(ed: ed, viewSize: fit)
                    } else {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text(ed.status ?? "").font(.system(size: 13)).foregroundStyle(SC.dim)
                        }
                    }
                }
                .frame(width: fit.width, height: fit.height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SC.wash(0.1)))
                .shadow(color: SC.shadow, radius: 30, y: 14)
                .shadow(color: SC.accent.opacity(0.16), radius: 60)
                .animation(SC.spring, value: ed.aspect)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            transport
        }
        .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(stageLight)
    }

    /// A dark stage with a faint dot grid and a soft pool of the theme's light behind the video.
    private var stageLight: some View {
        ZStack {
            SC.bg
            RadialGradient(colors: [SC.accent.opacity(SC.dark ? 0.14 : 0.1), .clear], center: .center, startRadius: 20, endRadius: 520)
            Canvas { ctx, size in
                let step: CGFloat = 22
                var y: CGFloat = step / 2
                while y < size.height {
                    var x: CGFloat = step / 2
                    while x < size.width {
                        ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.4, height: 1.4)), with: .color(SC.wash(0.05)))
                        x += step
                    }
                    y += step
                }
            }
        }
    }

    private func fitted(_ aspect: CGFloat, in s: CGSize) -> CGSize {
        guard s.width > 0, s.height > 0, aspect > 0 else { return .zero }
        return s.width / s.height > aspect ? CGSize(width: s.height * aspect, height: s.height) : CGSize(width: s.width, height: s.width / aspect)
    }

    private var transport: some View {
        VStack(spacing: 4) {
            Scrubber(ed: ed).padding(.horizontal, 6).padding(.top, 8)
            controls
        }
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial).opacity(0.7))
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SC.raised.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(SC.edge))
        .frame(maxWidth: 620)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text(clock(ed.time)).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(SC.text).frame(width: 74, alignment: .leading)
            Spacer()
            IconButton(icon: "backward.end.fill", help: "Previous cut") { ed.jump(-1) }
            IconButton(icon: "gobackward.5", help: "Back 5 seconds") { ed.player.pause(); ed.seek(ed.time - 5) }
            Button { ed.togglePlay() } label: {
                Image(systemName: ed.playing ? "pause.fill" : "play.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44).background(Circle().fill(SC.gradient))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25)))
                    .shadow(color: SC.accent.opacity(ed.playing ? 0.7 : 0.45), radius: ed.playing ? 16 : 10)
                    .animation(SC.spring, value: ed.playing)
            }
            .buttonStyle(Springy(hoverScale: 1.07)).help("Play or pause (Space)")
            IconButton(icon: "goforward.5", help: "Forward 5 seconds") { ed.player.pause(); ed.seek(ed.time + 5) }
            IconButton(icon: "forward.end.fill", help: "Next cut") { ed.jump(1) }
            Spacer()
            Text(clock(ed.editedLength)).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(SC.faint)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 4).frame(height: 52)
    }

    private var timelineDivider: some View {
        ZStack {
            Rectangle().fill(SC.line).frame(height: 1)
            Capsule().fill(SC.wash(0.18)).frame(width: 36, height: 4)
        }
        .frame(height: 9)
        .background(SC.panel)
        .contentShape(Rectangle())
        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
        .gesture(DragGesture(minimumDistance: 1).onChanged { v in
            timelineHeight = min(440, max(170, timelineHeight - v.translation.height))
        })
    }

    // MARK: Keyboard

    private func installKeys() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak ed] e in
            guard let ed, let window = e.window, window.isKeyWindow else { return e }
            // Typing in a text box keeps its keys.
            if let r = window.firstResponder as? NSTextView, r.isEditable { return e }
            if window.firstResponder is TranscriptTextView, [51, 117].contains(e.keyCode) { return e }
            let cmd = e.modifierFlags.contains(.command), shift = e.modifierFlags.contains(.shift)
            switch (e.keyCode, e.charactersIgnoringModifiers?.lowercased() ?? "") {
            case (49, _): ed.togglePlay()
            case (123, _): if cmd { ed.seek(0) } else if shift { ed.step(frames: -1) } else { ed.seek(ed.time - 5) }
            case (124, _): if cmd { ed.seek(ed.editedLength) } else if shift { ed.step(frames: 1) } else { ed.seek(ed.time + 5) }
            case (51, _), (117, _): ed.deleteSelection()
            case (53, _): ed.selection = .none; NSApp.keyWindow?.makeFirstResponder(nil)
            case (_, "z") where cmd: if shift { ed.redoLast() } else { ed.undoLast() }
            case (_, "d") where cmd: ed.duplicateSelection()
            case (_, "a") where cmd: ed.selectRange(0, ed.editedLength)
            case (_, "s") where !cmd: ed.split()
            case (_, "m") where !cmd && ed.selectionSpan != nil: ed.moveSelectionHere()
            case (_, "[") where !cmd && ed.selectionSpan != nil: ed.startSelectionHere()
            case (_, "]") where !cmd && ed.selectionSpan != nil: ed.endSelectionHere()
            case (_, ",") where !cmd && ed.selectionSpan != nil: ed.nudgeSelection(by: shift ? -1 : -0.1)
            case (_, ".") where !cmd && ed.selectionSpan != nil: ed.nudgeSelection(by: shift ? 1 : 0.1)
            case (_, "b") where cmd: ed.split()
            case (_, "t") where !cmd: ed.addText(ReelEditor.textPresets[0].item)
            case (_, "z") where !cmd: ed.addZoom()
            case (_, "k") where !cmd: ed.player.pause()
            case (_, "l") where !cmd: ed.togglePlay()
            case (_, "j") where !cmd: ed.player.pause(); ed.seek(ed.time - 2)
            default: return e
            }
            return nil
        }
    }
}
