// Test hooks for the editor that never show anything on screen or take any shortcuts, so they can run
// while someone is using the Mac. Both quit when they're done and write what happened to the log.
//
//   --studiorender <recording> <plan.json> <shape> <out.mp4>   saves a video with that edit
//   --studioshot <recording> <out.png> [tool] [plan.json] [selection]   draws the editor window into a picture
//   --brandshot <out.png>   draws Mercury's logo pieces (chat picture, menu bar planet, themes) into a picture
//
// <recording> is a file in Mercury Recordings or a full path. A plan given here is never saved over the
// recording's own edit unless the recording is a copy.

import AppKit
import AVFoundation
import SwiftUI

@MainActor
enum StudioTests {
    static func run(_ args: [String]) -> Bool {
        if let i = args.firstIndex(of: "--studiorender"), i + 4 < args.count {
            Task { await render(file(args[i + 1]), plan: args[i + 2], shape: args[i + 3], out: args[i + 4]) }
            return true
        }
        // `--studioaudio <recording> enhance|echo|polish...` runs the sound studio and logs what it did.
        if let i = args.firstIndex(of: "--studioaudio"), i + 1 < args.count {
            let url = file(args[i + 1])
            let opts = Set(args[(i + 2)...].prefix { !$0.hasPrefix("--") })
            let r = AudioRecipe(micEnhance: opts.contains("enhance") ? 0.85 : 0, sysEnhance: opts.contains("enhance") ? 0.85 : 0,
                                echo: opts.contains("echo"), polish: opts.contains("polish"), target: opts.contains("social") ? -14 : nil)
            Task {
                let t0 = Date()
                do {
                    let res = try await AudioStudio.process(url, r) { _ in }
                    let st = res.stats.sorted { $0.key < $1.key }.map { "t\($0.key) \(String(format: "%.1f LUFS, peak %.2f", -0.691 + 10 * log10(max($0.value.power, 1e-12)), $0.value.peak))" }
                    log("studioaudio: \(Int(Date().timeIntervalSince(t0))) s, echo \(res.echoDelay.map { String(format: "%.3f s", $0) } ?? "none"), \(st.joined(separator: "; ")), files \(res.files.sorted { $0.key < $1.key }.map(\.value))")
                } catch { log("studioaudio: \(error.localizedDescription)") }
                NSApp.terminate(nil)
            }
            return true
        }
        // `--drawshot <out.png>`: the drawing layer with hand-wobbly strokes (tidied into shapes) and its toolbar, as a picture.
        if let i = args.firstIndex(of: "--drawshot"), i + 1 < args.count {
            let model = DrawModel()
            func wobble(_ pts: [CGPoint]) -> [CGPoint] { pts.enumerated().map { CGPoint(x: $1.x + CGFloat(sin(Double($0) * 1.7)) * 3, y: $1.y + CGFloat(cos(Double($0) * 2.3)) * 3) } }
            func stroke(_ pts: [CGPoint], _ c: Int, tidy: Bool = true, marker: Bool = false) {
                var s = Stroke(kind: .free, points: wobble(pts), color: DrawModel.colors[c], width: marker ? 18 : 6, marker: marker)
                s.finished = true
                if tidy { s = ShapeGuess.tidy(s) }
                model.strokes.append(s)
                log("drawshot: stroke became \(s.kind)")
            }
            var line: [CGPoint] = []
            for k in 0..<40 { line.append(CGPoint(x: 80 + Double(k) * 8, y: 90 + Double(k) * 2)) }
            var box: [CGPoint] = []
            for t in 0..<30 { box.append(CGPoint(x: 520 + Double(t) * 8, y: 60)) }
            for t in 0..<20 { box.append(CGPoint(x: 760, y: 60 + Double(t) * 7)) }
            for t in 0..<30 { box.append(CGPoint(x: 760 - Double(t) * 8, y: 200)) }
            for t in 0..<21 { box.append(CGPoint(x: 520, y: 200 - Double(t) * 7)) }
            var circle: [CGPoint] = [], scribble: [CGPoint] = []
            for k in 0...60 { let a: Double = Double(k) / 60 * 2 * Double.pi; circle.append(CGPoint(x: 260 + cos(a) * 110, y: 330 + sin(a) * 80)) }
            for k in 0..<80 { let x: Double = 520 + Double(k) * 4; let y: Double = 330 + sin(Double(k) / 4) * 40 + Double(k); scribble.append(CGPoint(x: x, y: y)) }
            stroke(line, 2); stroke(box, 5); stroke(circle, 3); stroke(scribble, 0)
            stroke((0..<50).map { CGPoint(x: 100 + Double($0) * 9, y: 480) }, 3, tidy: false, marker: true)
            model.strokes.append(Stroke(kind: .arrow, points: [CGPoint(x: 620, y: 520), CGPoint(x: 820, y: 440)], color: DrawModel.colors[4], width: 6, finished: true))
            let view = DrawView(model: model)
            view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
            let bg = NSView(frame: view.frame)
            bg.wantsLayer = true
            bg.layer?.backgroundColor = NSColor(white: 0.93, alpha: 1).cgColor
            bg.addSubview(view)
            let bar = NSHostingView(rootView: DrawToolbar(model: model))
            bar.frame = NSRect(origin: CGPoint(x: (900 - bar.fittingSize.width) / 2, y: 530), size: bar.fittingSize)
            bg.addSubview(bar)
            let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = bg
            w.alphaValue = 0
            w.orderFrontRegardless()
            window = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let rep = bg.bitmapImageRepForCachingDisplay(in: bg.bounds) else { NSApp.terminate(nil); return }
                bg.cacheDisplay(in: bg.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
                log("drawshot: saved")
                NSApp.terminate(nil)
            }
            return true
        }
        if args.contains("--studiologic") {
            func w(_ t: String, _ a: Double, _ b: Double) -> Word { Word(text: t, start: a, end: b) }
            let old = [w("Imagine", 0, 0.5), w("the", 0.5, 0.7), w("swear", 0.7, 1.1), w("root", 1.1, 1.5), w("problem", 1.6, 2.2)]
            for new in [["Imagine", "the", "square", "root", "problem"], ["Imagine", "the", "square", "root", "conundrum", "problem"],
                        ["the", "square", "root"], ["Imagine", "a", "brand", "new", "the", "swear", "root", "problem"]] {
                let r = ReelEditor.realign(old, new)
                log("studiologic: " + r.map { String(format: "%@[%.2f-%.2f]", $0.text, $0.start, $0.end) }.joined(separator: " "))
            }
            NSApp.terminate(nil)
            return true
        }
        // `--studioplay <recording>`: play, pause, change the look, play again; logs whether the clock keeps up.
        if let i = args.firstIndex(of: "--studioplay"), i + 1 < args.count {
            shotWindow(file(args[i + 1]))
            func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
            after(5) {
                guard let ed = EditorPage.lastEditor else { log("studioplay: no editor"); NSApp.terminate(nil); return }
                ed.seek(1); ed.togglePlay()
                after(2) {
                    let t1 = ed.time, p1 = ed.playing
                    ed.togglePlay()
                    after(0.6) {
                        let p2 = ed.playing
                        UserDefaults.standard.set(UserDefaults.standard.string(forKey: "studioTheme") == "dark" ? "light" : "dark", forKey: "studioTheme")
                        after(1.5) {
                            let before = ed.time
                            ed.togglePlay()
                            after(2) {
                                log(String(format: "studioplay: first play %@ at %.2f s; after pause playing=%@; after changing the look, time moved %.2f s, playing=%@",
                                           p1 ? "playing" : "NOT playing", t1, p2 ? "yes" : "no", ed.time - before, ed.playing ? "yes" : "no"))
                                ed.player.pause()
                                UserDefaults.standard.removeObject(forKey: "studioTheme")
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
            return true
        }
        if let i = args.firstIndex(of: "--studiolive"), i + 1 < args.count {
            live(file(args[i + 1]))
            return true
        }
        if let i = args.firstIndex(of: "--brandshot"), i + 1 < args.count {
            let swatches = HStack(spacing: 8) {
                ForEach(BubbleTheme.all) { t in
                    Circle().fill(LinearGradient(colors: [Color(nsColor: t.start), Color(nsColor: t.end)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 28, height: 28)
                }
            }
            let menu = { (dark: Bool) in
                Image(nsImage: Brand.menuPlanet).renderingMode(.template).foregroundStyle(dark ? .white : .black)
                    .padding(8).background(dark ? Color(white: 0.15) : Color(white: 0.93))
            }
            let view = VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 24) { Avatar(emoji: "", size: 22); Avatar(emoji: "", size: 30); Avatar(emoji: "", size: 96); Avatar(emoji: "🦊", size: 30) }
                HStack(spacing: 12) { menu(true); menu(false) }
                swatches
            }
            .padding(30).background(Color(red: 0.07, green: 0.08, blue: 0.11))
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                log("brandshot: wrote \(args[i + 1]), planet image \(Brand.planet == nil ? "missing" : "found")")
            }
            NSApp.terminate(nil)
            return true
        }
        if let i = args.firstIndex(of: "--mainshot"), i + 1 < args.count {
            // The main window offscreen, in the theme passed as -windowTheme (light or dark) and the page passed
            // as -page. Both come from the command line only, so the real settings are never changed.
            let host = NSHostingView(rootView: MainView(model: UIModel(), dictation: DictationModel()).frame(width: 1100, height: 740))
            let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1100, height: 740), styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: UserDefaults.standard.string(forKey: "windowTheme") == "dark" ? .darkAqua : .aqua)
            w.contentView = host
            w.orderBack(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
                }
                log("mainshot: wrote \(args[i + 1])")
                NSApp.terminate(nil)
            }
            return true
        }
        if let i = args.firstIndex(of: "--drillshot"), i + 1 < args.count {
            // The text box with the + button and a running stopwatch, and the + menu. Reads settings, never writes them.
            let over = DrillTimer(), under = DrillTimer(), idle = DrillTimer()
            over.fakeForTesting(laps: [41, 63], split: 72)
            under.fakeForTesting(laps: [], split: 12)
            let bar = { (t: DrillTimer, text: String) in
                VStack(alignment: .leading, spacing: 7) {
                    DrillStrip(timer: t)
                    HStack(spacing: 8) {
                        ChatToolsButton(timer: t)
                        Text(text).font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 26, height: 26).background(Circle().fill(.white))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.1)))
                .frame(width: 420)
            }
            let view = HStack(alignment: .top, spacing: 30) {
                VStack(spacing: 18) {
                    bar(idle, "Ask, or press ⌥⇧\\ and say it…")
                    bar(under, "Ask, or press ⌥⇧\\ and say it…")
                    bar(over, "Q3 I think it's x = 2, is that right?")
                }
                ChatToolsButton(timer: idle).menu.background(PanelCard.fill).environment(\.colorScheme, .dark)
            }
            .padding(30).background(Color(red: 0.14, green: 0.15, blue: 0.18))
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                log("drillshot: wrote \(args[i + 1])")
            }
            NSApp.terminate(nil)
            return true
        }
        if let i = args.firstIndex(of: "--studioshot"), i + 2 < args.count {
            let rest = Array(args[(i + 3)...].prefix { !$0.hasPrefix("--") })
            shot(file(args[i + 1]), out: args[i + 2], tool: rest.first, plan: rest.count > 1 ? rest[1] : nil, select: rest.count > 2 ? rest[2] : nil)
            return true
        }
        return false
    }

    private static func file(_ s: String) -> URL { s.hasPrefix("/") ? URL(fileURLWithPath: s) : Settings.folder.appendingPathComponent(s) }

    private static func analysis(_ url: URL) async -> Analysis? {
        if let a = Analyzer.load(Analysis.self, Analyzer.cacheURL(for: url, "analysis")), a.words != nil { return a }
        guard var a = try? await Analyzer.levels(of: url) else { return nil }
        if Whisper.ready { a.words = try? await Whisper.transcribe(url, voiced: Cutter.voiced(a)) { _ in }; a.engine = "whisper" }
        Analyzer.save(a, Analyzer.cacheURL(for: url, "analysis"))
        return a
    }

    private static func render(_ url: URL, plan path: String, shape: String, out: String) async {
        let t0 = Date()
        defer { NSApp.terminate(nil) }
        guard let a = await analysis(url) else { log("studiorender: couldn't read \(url.lastPathComponent)"); return }
        guard let data = FileManager.default.contents(atPath: path), let plan = try? JSONDecoder().decode(EditPlan.self, from: data) else {
            log("studiorender: couldn't read the plan"); return
        }
        let size = ReelSize(rawValue: shape) ?? .vertical
        let tl = EditTimeline(spans: Cutter.spans(a, plan), plan: plan)
        do {
            let b = try await ReelBuilder.build(url: url, timeline: tl, plan: plan, size: size, words: plan.words ?? a.words, voiced: Cutter.voiced(a))
            try await ReelBuilder.export(b, to: URL(fileURLWithPath: out)) { _ in }
            log("studiorender: \(tl.pieces.count) pieces, \(String(format: "%.1f", tl.duration)) s, \(plan.texts.count) texts, \(plan.zooms.count) zooms, \(Int(Date().timeIntervalSince(t0))) s")
        } catch {
            log("studiorender: failed: \(error.localizedDescription)")
        }
    }

    private static var window: NSWindow?
    private static var output: AVPlayerItemVideoOutput?

    /// Checks a paused preview shows a change of look straight away, without rebuilding the video:
    /// reads the frame, turns the colour off, reads it again.
    private static func live(_ url: URL) {
        shotWindow(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard let ed = EditorPage.lastEditor, let item = ed.player.currentItem else { log("studiolive: no editor"); NSApp.terminate(nil); return }
            let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(out)
            output = out
            ed.seek(5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let before = saturation(out, item)
                ed.beginChange()
                ed.plan.canvas.background = "color"
                ed.plan.canvas.color = "FFFFFF"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let after = saturation(out, item)
                    log(String(format: "studiolive: brightness before %.3f, after %.3f (%@)", before ?? -1, after ?? -1,
                               (after ?? 0) > (before ?? 1) + 0.2 ? "redrawn" : "NOT redrawn"))
                    ed.undoLast()
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private static func saturation(_ out: AVPlayerItemVideoOutput, _ item: AVPlayerItem) -> Double? {
        guard let px = out.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) else { return nil }
        CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(px) else { return nil }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px), row = CVPixelBufferGetBytesPerRow(px)
        var total = 0.0, n = 0.0
        for y in stride(from: 0, to: h, by: 8) {
            let p = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: w, by: 8) {
                let b = Double(p[x * 4]), g = Double(p[x * 4 + 1]), r = Double(p[x * 4 + 2])
                total += (r + g + b) / 3; n += 1
            }
        }
        return total / max(1, n) / 255
    }

    private static func shotWindow(_ url: URL) {
        let host = NSHostingView(rootView: EditorPage(url: url, onClose: {}).frame(width: 1280, height: 800))
        let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.alphaValue = 0
        w.orderFrontRegardless()
        window = w
    }

    private static func shot(_ url: URL, out: String, tool: String?, plan: String?, select: String?) {
        let page = EditorPage(url: url, onClose: {})
        let host = NSHostingView(rootView: page.frame(width: 1280, height: 800).environment(\.colorScheme, .light))
        let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.alphaValue = 0
        w.orderFrontRegardless()   // off screen and see-through: SwiftUI only lays out windows that are ordered in
        window = w
        // Find the editor once SwiftUI has made it, then set it up for the picture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard let ed = EditorPage.lastEditor else { log("studioshot: no editor"); NSApp.terminate(nil); return }
            if let plan, let d = FileManager.default.contents(atPath: plan), let p = try? JSONDecoder().decode(EditPlan.self, from: d) { ed.plan = p }
            if let tool, let t = StudioTool(rawValue: tool) { ed.tool = t }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                switch select {
                case "piece": if let c = ed.timeline.clips.dropFirst(1).first ?? ed.timeline.clips.first { ed.select(.piece(c.src.start)) }
                case "text": if let t = ed.plan.texts.first { ed.select(.text(t.id)); if let s = ed.timeline.outputSpan(of: TimeSpan(start: t.start, end: t.end)) { ed.seek(s.start + 0.6) } }
                case "zoom": if let z = ed.plan.zooms.first { ed.select(.zoom(z.id)) }
                case "range": ed.selectRange(5, 12); ed.seek(5)
                case "video": if let v = ed.plan.videos.first { ed.select(.video(v.id)) }
                case "image": if let i = ed.plan.images.first { ed.select(.image(i.id)) }
                default: ed.seek(min(ed.editedLength, 6))
                }
                if tool == "colour" || tool == "canvas" { ed.size = .landscape }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    host.layoutSubtreeIfNeeded()
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { NSApp.terminate(nil); return }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    log("studioshot: \(out) (\(ed.timeline.pieces.count) pieces, tool \(ed.tool.rawValue))")
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
