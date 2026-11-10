// The editor's word panels: Text (titles and labels on the video), Subtitles (caption styles and cues)
// and Transcript (cut words straight from what was said).

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

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
