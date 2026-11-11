// SwiftUI interface: the main window (Home) and the floating recording pill.
// AppDelegate owns the behaviour; these views read and write `UIModel`.

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared state

final class UIModel: ObservableObject {
    @Published var camera = Settings.camera { didSet { Settings.camera = camera; onCamera?(camera) } }
    @Published var background = Settings.background { didSet { onBackground?(background) } }
    @Published var showThings = Settings.showThings { didSet { onShowThings?(showThings) } }
    @Published var bubbleSize = Settings.bubbleSize { didSet { onSize?(bubbleSize) } }
    @Published var mic = Settings.mic { didSet { Settings.mic = mic } }
    @Published var micDevice = Settings.micDevice { didSet { Settings.micDevice = micDevice } }
    @Published var micDevices: [(String, String)] = MicCapture.devices()
    @Published var noise = Settings.noiseSuppression { didSet { Settings.noiseSuppression = noise } }
    @Published var systemAudio = Settings.systemAudio { didSet { Settings.systemAudio = systemAudio } }
    @Published var countdown = Settings.countdown { didSet { Settings.countdown = countdown } }
    @Published var sounds = Settings.sounds { didSet { Settings.sounds = sounds } }
    @Published var autoName = Settings.autoName { didSet { Settings.autoName = autoName } }
    @Published var nameFromSpeech = Settings.nameFromSpeech { didSet { Settings.nameFromSpeech = nameFromSpeech } }
    @Published var micLevel: Float = 0      // 0...1 while recording
    @Published var micSilent = false        // nothing heard for a few seconds

    @Published var screenAllowed = CGPreflightScreenCaptureAccess()
    @Published var recents: [RecentRecording] = []
    /// The recording open in the reel editor, if any.
    @Published var editing: URL?
    @Published var importing = false

    // Recording pill
    /// True only while a recording is running, so the pill's animation stops the rest of the time.
    @Published var recording = false
    @Published var paused = false
    @Published var elapsed: TimeInterval = 0
    @Published var saving = false
    @Published var drawing = false          // drawing on the screen
    @Published var hasDrawings = false
    var onDraw: (() -> Void)?
    var onClearDrawings: (() -> Void)?

    var onCamera: ((Bool) -> Void)?
    var onBackground: ((CameraBackground) -> Void)?
    var onSize: ((CGFloat) -> Void)?
    var onShowThings: ((Bool) -> Void)?
    var onStart: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onPause: (() -> Void)?
    var onRestart: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onDone: (() -> Void)?
    var onDragPill: ((Bool) -> Void)?  // true = drag ended
    var onDictate: (() -> Void)?
    var onAssist: (() -> Void)?
    var onAssistKeysChanged: (() -> Void)?
    var onAllowAccessibility: (() -> Void)?

    var elapsedText: String {
        let s = Int(elapsed)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    struct ImportFailure: LocalizedError {
        var errorDescription: String? { "Mercury can't open this kind of video. MP4, MOV and M4V files work." }
    }

    /// Asks for a video, keeps a copy in Mercury Recordings so the original is never touched, and opens the editor.
    func importVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a video to edit. Mercury keeps its own copy in Mercury Recordings."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        importing = true
        Task { @MainActor in
            defer { importing = false }
            do {
                let copy = try await Self.importedCopy(of: source)
                refreshRecents()
                editing = copy
            } catch {
                log("import failed: \(error)")
                let alert = NSAlert()
                alert.messageText = "Couldn't import that video"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    static func importedCopy(of source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard playable, !tracks.isEmpty, videoExtensions.contains(source.pathExtension.lowercased()) else { throw ImportFailure() }
        let here = source.deletingLastPathComponent().standardizedFileURL
        if here == Settings.folder.standardizedFileURL || here == Settings.reelsFolder.standardizedFileURL { return source }
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        var dest = Settings.folder.appendingPathComponent(stem).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = Settings.folder.appendingPathComponent("\(stem) \(n)").appendingPathExtension(ext)
            n += 1
        }
        let target = dest
        try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: source, to: target) }.value
        log("imported: \(target.lastPathComponent)")
        return target
    }

    func refreshRecents() {
        let fm = FileManager.default
        func videos(in dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
                .filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix(".") }
        }
        let files = videos(in: Settings.folder) + videos(in: Settings.reelsFolder)
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        recents = dated.map { RecentRecording(url: $0.0, date: $0.1) }
        for item in recents { item.load() }
    }
}

final class RecentRecording: ObservableObject, Identifiable {
    let url: URL
    let date: Date
    @Published var thumbnail: NSImage?
    @Published var duration: String = ""
    var id: URL { url }

    init(url: URL, date: Date) { self.url = url; self.date = date }

    /// Made by the reel editor (saved in Mercury Recordings/Reels).
    var isReel: Bool { url.deletingLastPathComponent().standardizedFileURL == Settings.reelsFolder.standardizedFileURL }

    func load() {
        Task {
            let asset = AVURLAsset(url: url)
            if let d = try? await asset.load(.duration), d.seconds.isFinite {
                let s = Int(d.seconds.rounded())
                let text = String(format: "%d:%02d", s / 60, s % 60)
                await MainActor.run { self.duration = text }
            }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 240, height: 160)
            if let (cg, _) = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) {
                await MainActor.run { self.thumbnail = NSImage(cgImage: cg, size: .zero) }
            }
        }
    }
}

// MARK: - Look

struct BubbleTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let start: NSColor   // gradient start (top-left)
    let end: NSColor     // gradient end (bottom-right)

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static let all: [BubbleTheme] = [
        BubbleTheme(id: "mercury", name: "Mercury", start: rgb(0x2B4FD6), end: rgb(0x7FA4FF)),
        BubbleTheme(id: "volcanic", name: "Volcanic Gold", start: rgb(0xB8732E), end: rgb(0xEBBE6E)),
        BubbleTheme(id: "electric", name: "Electric Blue", start: rgb(0x1F5BFF), end: rgb(0x00B8FF)),
        BubbleTheme(id: "cobalt", name: "Cobalt", start: rgb(0x2433FF), end: rgb(0x7A5CFF)),
        BubbleTheme(id: "aqua", name: "Aqua", start: rgb(0x0091FF), end: rgb(0x00D9C0)),
        BubbleTheme(id: "violet", name: "Violet", start: rgb(0x7B3FFF), end: rgb(0xD04BFF)),
        BubbleTheme(id: "coral", name: "Coral", start: rgb(0xFF5C5C), end: rgb(0xED388C)),
        BubbleTheme(id: "graphite", name: "Graphite", start: rgb(0x2E3440), end: rgb(0x667085)),
    ]
}

/// The chosen colour theme, shared by every window. Default: Mercury's planet blue.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    @Published var current: BubbleTheme {
        didSet { UserDefaults.standard.set(current.id, forKey: "theme") }
    }
    private init() {
        let id = UserDefaults.standard.string(forKey: "theme") ?? "mercury"
        current = BubbleTheme.all.first { $0.id == id } ?? BubbleTheme.all[0]
    }
}

/// Mercury's planet logo (Planet.png in the app, drawn by tools/make_planet.py).
enum Brand {
    static let planet: NSImage? = Bundle.main.image(forResource: "Planet")

    /// The menu bar's planet: a disc with three craters cut out. It's a template image, so it
    /// follows the menu bar's colour.
    static let menuPlanet: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let p = NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2))
            p.windingRule = .evenOdd
            p.appendOval(in: NSRect(x: 5.4, y: 8.6, width: 3.8, height: 3.8))
            p.appendOval(in: NSRect(x: 10.2, y: 5.2, width: 2.8, height: 2.8))
            p.appendOval(in: NSRect(x: 10.8, y: 10.9, width: 2, height: 2))
            NSColor.black.setFill()
            p.fill()
            return true
        }
        img.isTemplate = true
        return img
    }()
}

enum Theme {
    static var brand: LinearGradient {
        LinearGradient(colors: [Color(nsColor: ThemeStore.shared.current.start), Color(nsColor: ThemeStore.shared.current.end)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var accent: Color { Color(nsColor: nsAccent) }
    /// The midpoint of the gradient, for strokes, rings and highlights.
    static var nsAccent: NSColor {
        ThemeStore.shared.current.start.blended(withFraction: 0.35, of: ThemeStore.shared.current.end) ?? ThemeStore.shared.current.start
    }
    static let card = Color.primary.opacity(0.045)
    static let stroke = Color.primary.opacity(0.08)
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Lets clicks land on the first try in panels that aren't the key window.
final class FirstClickHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct BackgroundTile: View {
    let kind: CameraBackground
    let selected: Bool
    let action: () -> Void

    private var name: String {
        switch kind { case .off: return "None"; case .blur: return "Blur"; case .grey: return "Grey"; case .clear: return "Cut-out" }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    swatch
                    Image(systemName: "person.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(kind == .grey ? Color.white.opacity(0.9) : Color.black.opacity(0.55))
                        .offset(y: 6)
                }
                .frame(height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 2 : 1))
                Text(name).font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var swatch: some View {
        switch kind {
        case .off:
            RoomScene()
        case .blur:
            RoomScene().blur(radius: 4)
        case .grey:
            Color(red: 0.17, green: 0.17, blue: 0.19)
        case .clear:
            Checkerboard()
        }
    }
}

/// A tiny "room" (window, shelf, plant) so None and Blur look clearly different.
struct RoomScene: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.86, green: 0.82, blue: 0.74), Color(red: 0.74, green: 0.68, blue: 0.6)],
                           startPoint: .top, endPoint: .bottom)
            RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.62, green: 0.8, blue: 0.95))
                .frame(width: 22, height: 16).offset(x: 8, y: 7)
            Rectangle().fill(Color(red: 0.45, green: 0.32, blue: 0.22)).frame(width: 30, height: 3).offset(x: 52, y: 14)
            Circle().fill(Color(red: 0.3, green: 0.6, blue: 0.35)).frame(width: 12, height: 12).offset(x: 62, y: 26)
        }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 6
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.25)))
                }
            }
        }
        .background(Color.white.opacity(0.6))
    }
}

// MARK: - Recording pill

struct RecordingPill: View {
    @ObservedObject var model: UIModel
    @ObservedObject private var themes = ThemeStore.shared
    var body: some View {
        HStack(spacing: 4) {
            // Drag handle + status
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(model.paused ? Color.orange : Color.red).frame(width: 10, height: 10)
                    // The pill exists from launch, hidden. The ring only animates while a recording is running,
                    // so an idle Mercury never redraws anything (an endless animation here kept every Mac busy).
                    if !model.paused && model.recording {
                        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                            let k = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                            Circle().stroke(Color.red.opacity(0.6), lineWidth: 2)
                                .frame(width: 10, height: 10)
                                .scaleEffect(1 + 1.2 * (1 - pow(1 - k, 2))).opacity(1 - k)
                        }
                    }
                }
                Text(model.saving ? "Saving…" : model.paused ? "Paused" : model.elapsedText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(model.paused ? Color.orange : .white)
                    .frame(width: 62, alignment: .leading)
                if model.mic { MicMeter(level: model.micLevel, silent: model.micSilent) }
            }
            .padding(.leading, 14).padding(.trailing, 6)
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { _ in model.onDragPill?(false) }
                .onEnded { _ in model.onDragPill?(true) })
            .help("Drag to move")

            Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 22)

            PillIcon(icon: "pencil.tip.crop.circle", tip: model.drawing ? "Stop drawing (Esc)" : "Draw on the screen (it's recorded)", on: model.drawing) { model.onDraw?() }
            PillIcon(icon: "eraser.line.dashed", tip: "Clear all drawings") { model.onClearDrawings?() }
                .opacity(model.hasDrawings ? 1 : 0.35)
                .disabled(!model.hasDrawings)
            Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 22)
            PillIcon(icon: model.paused ? "play.fill" : "pause.fill", tip: model.paused ? "Resume" : "Pause") { model.onPause?() }
            PillIcon(icon: "arrow.counterclockwise", tip: "Restart (discard and start again)") { model.onRestart?() }
            PillIcon(icon: "trash", tip: "Discard recording") { model.onDiscard?() }

            Button { model.onDone?() } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 9, height: 9)
                    Text("Done").font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 32)
                .background(Capsule().fill(Theme.brand))
            }
            .buttonStyle(.plain)
            .help("Finish and open the video")
            .padding(.leading, 4).padding(.trailing, 6)
        }
        .disabled(model.saving)
        .background(
            ZStack {
                VisualEffect(material: .hudWindow)
                Color.black.opacity(0.35)
            }
            .clipShape(Capsule())
        )
        .overlay(Capsule().stroke(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .id(themes.current.id)
    }
}

/// Four little bars that bounce with your voice; turns into an amber warning if the mic is silent.
struct MicMeter: View {
    let level: Float
    let silent: Bool

    var body: some View {
        Group {
            if silent {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .help("Your microphone isn't picking up any sound. Check the Mic setting.")
            } else {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<4) { i in
                        let weights: [Float] = [0.55, 1, 0.8, 0.45]
                        let h = 4 + 14 * CGFloat(min(1, level * weights[i] * 1.4))
                        Capsule().fill(Theme.accent.opacity(0.95)).frame(width: 3, height: h)
                    }
                }
                .frame(height: 18)
                .animation(.easeOut(duration: 0.12), value: level)
                .help("Microphone level")
            }
        }
        .frame(width: 20)
    }
}

struct PillIcon: View {
    let icon: String
    let tip: String
    var on = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(hover || on ? 1 : 0.85))
                .frame(width: 32, height: 32)
                .background(Circle().fill(on ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.white.opacity(hover ? 0.16 : 0))))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(tip)
    }
}

// MARK: - Chat box

/// The box you type into in Ask Mercury and the reel editor. It's a real Mac text view rather than
/// SwiftUI's growing text field, which re-measures every line on each redraw and slowed the whole app
/// to a crawl with a long pasted prompt. Return sends; Shift+Return or Option+Return starts a new line.
/// It grows up to `maxLines`, then scrolls.
struct ChatTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont = .systemFont(ofSize: 13)
    var textColor: NSColor = .labelColor
    var placeholderColor: NSColor = .placeholderTextColor
    var maxLines = 6
    /// Change it to put the cursor in the box.
    var focusRequest = 0
    @Binding var height: CGFloat
    var onSubmit: () -> Void

    final class Box: NSTextView {
        var placeholder = "" { didSet { needsDisplay = true } }
        var placeholderColor: NSColor = .placeholderTextColor
        override func draw(_ rect: NSRect) {
            super.draw(rect)
            guard string.isEmpty, !placeholder.isEmpty else { return }
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
                                           withAttributes: [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: placeholderColor])
        }
        override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatTextView
        var lastFocus = 0
        init(_ p: ChatTextView) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            report(tv)
        }

        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            if mods.contains(.shift) || mods.contains(.option) { tv.insertNewlineIgnoringFieldEditor(nil); return true }
            parent.onSubmit()
            return true
        }

        func report(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let line = lm.defaultLineHeight(for: tv.font ?? .systemFont(ofSize: 13))
            let h = min(max(line, lm.usedRect(for: tc).height), line * CGFloat(parent.maxLines)).rounded(.up)
            if abs(parent.height - h) > 0.5 { DispatchQueue.main.async { self.parent.height = h } }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let tv = Box(frame: .zero)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = font
        tv.textColor = textColor
        tv.insertionPointColor = textColor
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.placeholder = placeholder
        tv.placeholderColor = placeholderColor
        tv.string = text
        scroll.documentView = tv
        DispatchQueue.main.async { context.coordinator.report(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? Box else { return }
        if tv.string != text {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.report(tv)
        }
        if tv.placeholder != placeholder { tv.placeholder = placeholder }
        if focusRequest != context.coordinator.lastFocus {
            context.coordinator.lastFocus = focusRequest
            // Never pulls the keyboard to the panel by itself; it only moves the cursor in a window you're already typing in.
            DispatchQueue.main.async { if tv.window?.isKeyWindow == true { tv.window?.makeFirstResponder(tv) } }
        }
    }
}

// MARK: - Dark panels and their popovers
//
// Mercury's floating panels (Ask Mercury, the dictation pill, recording controls, the drawing
// toolbar) are always dark. Setting SwiftUI's colour scheme to dark isn't enough on its own:
// popovers, menus and tooltips are drawn by macOS from the *window's* appearance, which follows
// the Mac's light or dark mode. In light mode that gave pale frosted popovers holding white text
// from the panel, which was unreadable. So: every always-dark panel calls `alwaysDark()`, and
// every popover from one uses `panelPopover`, never plain `.popover`.

extension NSWindow {
    /// Draw this window, and everything macOS adds to it, in dark mode whatever the Mac is set to.
    func alwaysDark() { appearance = NSAppearance(named: .darkAqua) }
}

enum PanelCard {
    static let fill = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let text = Color.white
    static let subtle = Color.white.opacity(0.62)
    static let line = Color.white.opacity(0.12)
    static let field = Color.white.opacity(0.1)
}

extension View {
    /// A solid dark card with white text, readable over anything behind the see-through panel.
    func solidPopover() -> some View {
        presentationBackground(PanelCard.fill).environment(\.colorScheme, .dark)
    }

    /// The only popover to use from a dark panel: always a solid dark card.
    func panelPopover<Content: View>(isPresented: Binding<Bool>, arrowEdge: Edge = .bottom, @ViewBuilder content: @escaping () -> Content) -> some View {
        popover(isPresented: isPresented, arrowEdge: arrowEdge) { content().solidPopover() }
    }
}
