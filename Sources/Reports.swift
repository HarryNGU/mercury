// Report a Problem: a small window where anyone can tell Harry what went wrong, in words, with a
// screenshot they can circle and draw on, or with a short screen recording. Mercury has no server,
// so the report becomes an email with everything attached that the person sends themselves. If the
// Mac has no Mail account, the report is left in a folder, ready to attach anywhere.
// Nothing is sent without the person pressing Send in their own email.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Reports {
    /// Where reports are emailed, from Info.plist (MercuryReportsEmail). Blank leaves the To field for the person.
    static var address: String { (Bundle.main.object(forInfoDictionaryKey: "MercuryReportsEmail") as? String ?? "").trimmingCharacters(in: .whitespaces) }

    /// Version, Mac and setup details that help reproduce a problem. Nothing personal.
    static var systemInfo: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        #if arch(arm64)
        let chip = "Apple silicon"
        #else
        let chip = "Intel"
        #endif
        return """
        Mercury \(v) (\(b))
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Mac: \(String(cString: model)), \(chip)
        Brain: \(Settings.assistantBrain.title)
        Built in voice: \(Whisper.ready ? "ready" : (Whisper.binary == nil ? "not available" : "model not downloaded"))
        """
    }

    /// The end of Mercury's log. It records what Mercury did (like recording names), never what you typed or said.
    static func logTail(lines: Int = 3000) -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Bubble.log")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return "(no log yet)" }
        return s.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}

@MainActor
final class ReportModel: ObservableObject {
    @Published var text = ""
    @Published var shot: NSImage?          // with your markings
    @Published var rawShot: NSImage?       // as taken, to mark up again
    @Published var marking = false
    @Published var video: URL?
    @Published var files: [URL] = []
    @Published var includeLog = true
    @Published var status: String?

    var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || shot != nil || video != nil || !files.isEmpty }

    func reset() { text = ""; shot = nil; rawShot = nil; marking = false; video = nil; files = []; includeLog = true; status = nil }
}

@MainActor
final class ReportCenter: NSObject, NSWindowDelegate {
    static let shared = ReportCenter()
    let model = ReportModel()
    private var window: NSWindow?
    private(set) var waitingForRecording = false

    func show() {
        let w = window ?? makeWindow()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Report a Problem"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: ReportView(model: model, center: self))
        w.center()
        w.delegate = self
        return w
    }

    /// Steps aside, takes a picture of the screen, then comes back so you can draw on it.
    func takeScreenshot() {
        window?.orderOut(nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            let data = await ScreenGrab.jpeg(excluding: [])
            show()
            guard let data, let img = NSImage(data: data) else { model.status = "Couldn't take a screenshot. Mercury needs Screen Recording in System Settings."; return }
            model.rawShot = img
            model.shot = img
            model.marking = true
        }
    }

    /// Starts a normal Mercury recording; when you finish it, the video lands in this report.
    func recordProblem() {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        waitingForRecording = true
        window?.orderOut(nil)
        app.startPicker()
    }

    /// Called when a recording ends. True when it belonged to a report.
    @discardableResult
    func recordingFinished(_ url: URL?) -> Bool {
        guard waitingForRecording else { return false }
        waitingForRecording = false
        if let url { model.video = url }
        show()
        return true
    }

    func addFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        if p.runModal() == .OK { model.files += p.urls }
    }

    /// Writes the report into its own folder: the note, the marked up screenshot, the log. Returns the folder.
    func package() throws -> URL {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Mercury report \(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let note = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        try ((note.isEmpty ? "(no description)" : note) + "\n\n" + Reports.systemInfo + "\n").write(to: dir.appendingPathComponent("Report.txt"), atomically: true, encoding: .utf8)
        if let shot = model.shot, let tiff = shot.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: dir.appendingPathComponent("Screenshot.png"))
        }
        if model.includeLog { try Reports.logTail().write(to: dir.appendingPathComponent("Mercury log.txt"), atomically: true, encoding: .utf8) }
        return dir
    }

    /// Opens a new email with everything attached, or leaves the report in Finder if there's no Mail account.
    func send() {
        do {
            let dir = try package()
            let attachments = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent != "Report.txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                + [model.video].compactMap { $0 } + model.files
            let note = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = (note.isEmpty ? "(no description)" : note) + "\n\n----\n" + Reports.systemInfo
            let first = note.split(separator: "\n").first.map { String($0.prefix(60)) } ?? "a problem"
            if let mail = NSSharingService(named: .composeEmail), mail.canPerform(withItems: [body] + attachments) {
                if !Reports.address.isEmpty { mail.recipients = [Reports.address] }
                mail.subject = "Mercury problem: \(first)"
                mail.perform(withItems: [body as NSString] + attachments.map { $0 as NSURL })
                log("report: email opened with \(attachments.count) attachment(s)")
                model.status = "Your email is ready. Press Send there and it's on its way. Thank you!"
            } else {
                // No Mail account: keep everything together where it's easy to attach.
                for f in [model.video].compactMap({ $0 }) + model.files {
                    try? FileManager.default.copyItem(at: f, to: dir.appendingPathComponent(f.lastPathComponent))
                }
                NSWorkspace.shared.activateFileViewerSelecting([dir])
                if !Reports.address.isEmpty {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Reports.address, forType: .string)
                }
                log("report: saved to a folder (no Mail account)")
                model.status = Reports.address.isEmpty
                    ? "Your report is in the Finder window that just opened. Attach that folder to an email to Harry."
                    : "Your report is in the Finder window that just opened, and \(Reports.address) is copied. Attach the folder to an email to that address."
            }
        } catch {
            model.status = "Couldn't put the report together: \(error.localizedDescription)"
        }
    }
}

/// The report window.
struct ReportView: View {
    @ObservedObject var model: ReportModel
    let center: ReportCenter

    var body: some View {
        Group {
            if model.marking, let raw = model.rawShot {
                MarkupView(image: raw, onDone: { model.shot = $0; model.marking = false }, onCancel: { model.marking = false })
            } else {
                form
            }
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What went wrong?").font(.system(size: 20, weight: .semibold))
                Text("A few words is plenty. A screenshot or a quick recording helps even more.").foregroundStyle(.secondary)
            }
            TextEditor(text: $model.text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 130)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
            HStack(spacing: 10) {
                Button { center.takeScreenshot() } label: { Label("Screenshot", systemImage: "camera.viewfinder") }
                Button { center.recordProblem() } label: { Label("Record my screen", systemImage: "record.circle") }
                Button { center.addFiles() } label: { Label("Add a file", systemImage: "paperclip") }
            }
            .controlSize(.large)
            if model.shot != nil || model.video != nil || !model.files.isEmpty { attachments }
            HStack(spacing: 8) {
                Toggle("Include Mercury's log", isOn: $model.includeLog)
                Button("What's in it?") {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Bubble.log"))
                }
                .buttonStyle(.link)
            }
            Text("The log lists what Mercury did, like recording names and errors. It never holds what you typed, said or asked.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let s = model.status { Text(s).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Start over") { model.reset() }.disabled(!model.canSend)
                Spacer()
                Button("Send report") { center.send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.canSend)
            }
        }
        .padding(24)
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if let shot = model.shot {
                    tile(remove: { model.shot = nil; model.rawShot = nil }) {
                        Image(nsImage: shot).resizable().scaledToFill().frame(width: 140, height: 88).clipped()
                            .overlay(alignment: .bottomLeading) {
                                Button("Draw on it") { model.marking = true }.font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(.black.opacity(0.6))).foregroundStyle(.white)
                                    .buttonStyle(.plain).padding(6)
                            }
                    }
                }
                if let v = model.video { tile(remove: { model.video = nil }) { fileTile(v, icon: "film") } }
                ForEach(model.files, id: \.self) { f in tile(remove: { model.files.removeAll { $0 == f } }) { fileTile(f, icon: "doc") } }
            }
        }
    }

    private func fileTile(_ u: URL, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 22))
            Text(u.lastPathComponent).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center)
        }
        .padding(8).frame(width: 140, height: 88).background(Color.primary.opacity(0.06))
    }

    private func tile<C: View>(remove: @escaping () -> Void, @ViewBuilder _ c: () -> C) -> some View {
        c().clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain).padding(4).help("Remove")
            }
    }
}

/// Draw on the screenshot in red: circle what's wrong, underline it, point at it.
struct MarkupView: View {
    let image: NSImage
    let onDone: (NSImage) -> Void
    let onCancel: () -> Void
    @State private var strokes: [[CGPoint]]      // points from 0 to 1 across the picture
    @State private var current: [CGPoint] = []

    init(image: NSImage, strokes: [[CGPoint]] = [], onDone: @escaping (NSImage) -> Void, onCancel: @escaping () -> Void) {
        self.image = image; self.onDone = onDone; self.onCancel = onCancel
        _strokes = State(initialValue: strokes)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Circle or draw on what's wrong").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Undo") { _ = strokes.popLast() }.disabled(strokes.isEmpty).keyboardShortcut("z", modifiers: .command)
                Button("Clear") { strokes = [] }.disabled(strokes.isEmpty)
            }
            GeometryReader { geo in
                let s = fit(image.size, in: geo.size)
                ZStack {
                    Image(nsImage: image).resizable().frame(width: s.width, height: s.height)
                    Canvas { ctx, size in
                        for line in strokes + [current] where line.count > 1 {
                            var p = Path()
                            p.addLines(line.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
                            ctx.stroke(p, with: .color(.red), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        }
                    }
                    .frame(width: s.width, height: s.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        current.append(CGPoint(x: min(1, max(0, v.location.x / s.width)), y: min(1, max(0, v.location.y / s.height))))
                    }.onEnded { _ in
                        if current.count > 1 { strokes.append(current) }
                        current = []
                    })
                    .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Use this") { onDone(Self.render(image, strokes)) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
    }

    private func fit(_ img: CGSize, in box: CGSize) -> CGSize {
        guard img.width > 0, img.height > 0 else { return box }
        let k = min(box.width / img.width, box.height / img.height)
        return CGSize(width: img.width * k, height: img.height * k)
    }

    /// The screenshot at full size with the red markings on it.
    static func render(_ base: NSImage, _ lines: [[CGPoint]]) -> NSImage {
        let size = base.size
        return NSImage(size: size, flipped: true) { r in
            base.draw(in: r, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            NSColor.systemRed.setStroke()
            for line in lines where line.count > 1 {
                let p = NSBezierPath()
                p.lineWidth = max(3, size.width * 0.004)
                p.lineCapStyle = .round; p.lineJoinStyle = .round
                p.move(to: NSPoint(x: line[0].x * size.width, y: line[0].y * size.height))
                for q in line.dropFirst() { p.line(to: NSPoint(x: q.x * size.width, y: q.y * size.height)) }
                p.stroke()
            }
            return true
        }
    }
}
