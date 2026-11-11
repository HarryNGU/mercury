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
        if args.contains("--unittests") {
            exit(UnitTests.run() ? 0 : 1)
        }
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
            func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated(f) } }
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
        if args.contains("--redacttest") {
            // Made up 1440x900 frames, the second half showing a fake email address, fed through the blur
            // at 60 frames a second the way the recorder does. Checks no frame waits for the text reading
            // and the address still gets caught. Never touches the screen or the real recordings.
            let q = DispatchQueue(label: "bubble.writer.test")
            let r = Redactor(queue: q)
            r.warmUp()
            func frame(_ text: String) -> CMSampleBuffer? {
                let w = 1440, h = 900
                var px: CVPixelBuffer?
                CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &px)
                guard let px else { return nil }
                CVPixelBufferLockBaseAddress(px, [])
                let ctx = CGContext(data: CVPixelBufferGetBaseAddress(px), width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(px), space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                (text as NSString).draw(at: NSPoint(x: 120, y: 420), withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
                NSGraphicsContext.restoreGraphicsState()
                CVPixelBufferUnlockBaseAddress(px, [])
                var fd: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: px, formatDescriptionOut: &fd)
                var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
                var sb: CMSampleBuffer?
                CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: px, formatDescription: fd!, sampleTiming: &timing, sampleBufferOut: &sb)
                return sb
            }
            let plain = frame("Meeting notes for Thursday"), secret = frame("Contact: jane.doe@example.com")
            var waits: [Double] = [], late = 0, blurredFrames = 0
            r.onNewFinds = { late += 1 }
            for n in 0..<180 {
                let sb = (n < 60 ? plain : secret)!
                q.sync {
                    let t = CFAbsoluteTimeGetCurrent()
                    let out = r.process(sb)
                    waits.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
                    if CMSampleBufferGetImageBuffer(out) !== CMSampleBufferGetImageBuffer(sb) { blurredFrames += 1 }
                }
                Thread.sleep(forTimeInterval: 1.0 / 60)
            }
            q.sync {}
            let top = waits.enumerated().sorted { $0.element > $1.element }.prefix(4).map { String(format: "#%d %.1fms", $0.offset, $0.element) }
            log("redacttest: slowest frames \(top.joined(separator: ", "))")
            let sorted = waits.sorted()
            log(String(format: "redacttest: 180 frames, wait per frame median %.2f ms, worst %.2f ms; late finds %d; blurred frames %d of 120 with the address; spotted %d",
                       sorted[90], sorted.last ?? 0, late, blurredFrames, r.spotted))
            NSApp.terminate(nil)
            return true
        }
        if let i = args.firstIndex(of: "--importtest"), i + 1 < args.count {
            // Imports a file exactly as the Import video button does, without the file picker.
            Task { @MainActor in
                do { log("importtest: \(try await UIModel.importedCopy(of: URL(fileURLWithPath: args[i + 1])).path)") }
                catch { log("importtest: refused: \(error.localizedDescription)") }
                NSApp.terminate(nil)
            }
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
        if let i = args.firstIndex(of: "--panelshot"), i + 2 < args.count {
            // The chat at three sizes with a video in it, plus checks of the resizing maths and video detection.
            // Made up messages only; never reads or writes saved chats. Writes OUT-small, OUT-medium and OUT-large.
            let area = NSRect(x: 0, y: 0, width: 1600, height: 1000), s = NSRect(x: 300, y: 300, width: 700, height: 500)
            for (e, dx, dy) in [(PanelEdge.right, CGFloat(100), CGFloat(0)), (.left, 100, 0), (.bottom, 0, -50), (.top, 0, 2000), (.bottomRight, -900, 900), (.topLeft, -2000, -900)] {
                log("panelshot: \(e) \(dx),\(dy) -> \(PanelSizing.resized(s, edge: e, dx: dx, dy: dy, within: area))")
            }
            for line in ["/Users/me/Desktop/a b.mp4", "[[video: ~/Movies/x.mov]]", "![clip](/tmp/y.m4v)", "https://example.com/z.mp4?x=1", "/tmp/not.png", "Saved it to `/Users/me/Desktop/My Clip (final).mp4` for you", "It is at /tmp/q.mov.", "the mp4 is done"] {
                log("panelshot: blocks of '\(line)' -> \(RichAnswer.blocks(line))")
            }
            let model = AssistantModel(forTesting: true)
            model.seeScreen = false
            model.exchanges = [AssistantModel.Exchange(question: "make me a clip", answer: "Here you go.\n\n[[video: \(args[i + 2])]]\n\nA longer message so the wrapping shows at each panel size, which matters most when the panel is small.", withScreen: false, activity: nil)]
            let sizes: [(String, CGSize)] = [("small", CGSize(width: 400, height: 420)), ("mid", CGSize(width: 500, height: 420)), ("medium", CGSize(width: 640, height: 500)), ("large", CGSize(width: 1500, height: 900))]
            model.panelSize = sizes[0].1
            let host = NSHostingView(rootView: AssistantView(model: model, onClose: {}))
            host.sizingOptions = []   // as in the real panel, so the window really is the size asked for
            let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua); w.backgroundColor = NSColor(white: 0.25, alpha: 1)
            w.contentView = host; w.orderBack(nil)
            // The real panel type, far off screen: your size must stick, and Grow to Fit must let go of it.
            func windowCheck() {
                let p = AssistantPanel(contentRect: NSRect(x: -30000, y: -30000, width: 700, height: 60), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                let m = AssistantModel(forTesting: true)
                m.exchanges = model.exchanges
                let hc = NSHostingController(rootView: AssistantView(model: m, onClose: {}))
                hc.sizingOptions = []
                p.contentViewController = hc
                p.orderBack(nil)
                let wait = { (s: Double, f: @escaping @MainActor () -> Void) in DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated(f) } }
                wait(1) {
                    log("panelshot: window measured the conversation at \(m.fitSize)")
                    m.panelSize = CGSize(width: 500, height: 400)
                    p.setFrame(NSRect(x: -30000, y: -30000, width: 500, height: 400), display: true)
                    wait(1) {
                        log("panelshot: window held at 500x400 -> \(p.frame.size)")
                        m.panelSize = CGSize(width: 900, height: 700)
                        p.setFrame(NSRect(x: -30000, y: -30000, width: 900, height: 700), display: true)
                        wait(1) {
                            log("panelshot: window held at 900x700 -> \(p.frame.size)")
                            m.panelSize = nil
                            wait(1) {
                                log("panelshot: window measured again after letting go \(m.fitSize), inside a window of \(p.frame.size)")
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
            func step(_ n: Int) {
                guard n < sizes.count else { windowCheck(); return }
                model.panelSize = sizes[n].1
                w.setContentSize(sizes[n].1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    host.layoutSubtreeIfNeeded()
                    log("panelshot: asked \(sizes[n].1) got \(host.bounds.size)")
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1].replacingOccurrences(of: ".png", with: "-\(sizes[n].0).png")))
                    }
                    step(n + 1)
                }
            }
            step(0)
            return true
        }
        if let i = args.firstIndex(of: "--tourshot"), i + 1 < args.count {
            // One welcome tour scene offscreen (pick it with --onboard N), after its messages have typed in.
            // Starts no camera, mic or screen access; those only happen when you press a button.
            let host = NSHostingView(rootView: OnboardingView(permissions: Permissions(), onDone: {}).frame(width: 1000, height: 720))
            let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1000, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = host; w.orderBack(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
                }
                log("tourshot: wrote \(args[i + 1])")
                NSApp.terminate(nil)
            }
            return true
        }
        if let i = args.firstIndex(of: "--reportshot"), i + 1 < args.count {
            // The report window and the drawing step, offscreen, with a drawn stand in screenshot, plus the report
            // folder it would attach. Sends nothing and opens no email. Writes OUT.png and OUT-draw.png.
            let pic = NSImage(size: NSSize(width: 1200, height: 750), flipped: false) { r in
                NSColor(white: 0.93, alpha: 1).setFill(); r.fill()
                NSColor.systemBlue.setFill(); NSBezierPath(roundedRect: NSRect(x: 420, y: 300, width: 360, height: 120), xRadius: 16, yRadius: 16).fill()
                return true
            }
            let center = ReportCenter.shared, m = center.model
            m.text = "The record button did nothing the second time I pressed it."
            let ring = (0...40).map { k -> CGPoint in let a = Double(k) / 40 * 2 * .pi; return CGPoint(x: 0.5 + 0.18 * cos(a), y: 0.52 + 0.14 * sin(a)) }
            let mark = MarkupView(image: pic, strokes: [ring], onDone: { _ in }, onCancel: {})
            m.rawShot = pic
            m.shot = MarkupView.render(pic, [ring])
            func snap(_ v: some View, _ size: NSSize, _ path: String) {
                let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height))
                let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
                w.appearance = NSAppearance(named: .aqua); w.backgroundColor = .windowBackgroundColor
                host.wantsLayer = true; host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                w.contentView = host; w.orderBack(nil); host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                snap(ReportView(model: m, center: center), NSSize(width: 640, height: 600), args[i + 1])
                snap(mark, NSSize(width: 640, height: 600), args[i + 1].replacingOccurrences(of: ".png", with: "-draw.png"))
                if let dir = try? center.package() {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                    let note = (try? String(contentsOf: dir.appendingPathComponent("Report.txt"), encoding: .utf8)) ?? ""
                    log("reportshot: folder holds \(names.sorted()); note starts \(note.prefix(60).replacingOccurrences(of: "\n", with: " | ")); address set \(!Reports.address.isEmpty)")
                    try? FileManager.default.removeItem(at: dir)
                }
                NSApp.terminate(nil)
            }
            return true
        }
        if let i = args.firstIndex(of: "--arrivalshot"), i + 1 < args.count {
            // The welcome tour's shooting star arrival, offscreen, caught at four moments. No haptics, no sound
            // players loaded. Writes OUT-1.png to OUT-7.png.
            var shake = CGSize.zero
            let view = ZStack {
                Color(red: 0.03, green: 0.05, blue: 0.13)
                ArrivalIntro(shake: Binding(get: { shake }, set: { shake = $0 }), target: CGPoint(x: 500, y: 130)) { log("arrivalshot: finished") }
            }
            let host = NSHostingView(rootView: view.frame(width: 1000, height: 700))
            let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host; w.orderBack(nil)
            // The last three catch the planet gliding up into the welcome's small planet spot.
            for (k, at) in [0.4, 0.62, 2.0, 3.9, 4.55, 4.85, 5.35].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1].replacingOccurrences(of: ".png", with: "-\(k + 1).png")))
                    }
                    log("arrivalshot: frame \(k + 1) at \(at)s, shake \(Int(shake.width)),\(Int(shake.height))")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { NSApp.terminate(nil) }
            return true
        }
        if args.contains("--brainstest") {
            // Asks Mercury's live free AI one short question (uses one of this Mac's free messages), and checks the
            // OpenAI brain explains a missing key. Never reads or writes saved chats or settings.
            Task { @MainActor in
                var reply = ""
                do {
                    try await FreeAI.ask("In one short sentence: how do I check which version of my operating system I have?", history: [], screenshot: nil, transcript: "") { reply += $0 }
                    log("brainstest: free AI replied \"\(reply.replacingOccurrences(of: "\n", with: " ").prefix(160))\", \(FreeAI.remaining.map(String.init) ?? "?") left today")
                } catch { log("brainstest: free AI failed: \(error.localizedDescription)") }
                let saved = Settings.d.string(forKey: "openAIBaseURL")
                do { try await OpenAIClient.ask("hi", history: [], screenshot: nil, transcript: "") { _ in } ; log("brainstest: openai answered") }
                catch { log("brainstest: openai without key says: \(error.localizedDescription)") }
                if saved == nil { Settings.d.removeObject(forKey: "openAIBaseURL") }
                NSApp.terminate(nil)
            }
            return true
        }
        if args.contains("--focustest") {
            // The panel's keyboard rules, offscreen: it only takes the keyboard on request, never while locked,
            // and Claude's computer driving tools are recognised. Touches no settings or chats.
            for (tool, cmd) in [("Bash", "osascript -e 'tell application \"System Events\" to keystroke \"hi\"'"), ("Bash", "ls -la ~/Desktop"),
                                ("mcp__computer-use__left_click", ""), ("Bash", "python3 -c 'import Quartz; Quartz.CGEventPost(0, e)'"), ("Read", "")] {
                log("focustest: \(tool) \(cmd.prefix(40)) -> controls Mac \(ClaudeCodeSession.controlsComputer(tool, ["command": cmd]))")
            }
            let p = AssistantPanel(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.becomesKeyOnlyIfNeeded = true
            p.contentView = NSView()
            p.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                log("focustest: shown, key \(p.isKeyWindow)")
                p.makeKey()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    log("focustest: after you click the box, key \(p.isKeyWindow)")
                    p.keyboardLocked = true
                    p.handBackKeyboard()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        log("focustest: Claude driving: key \(p.isKeyWindow), visible \(p.isVisible), can take keyboard \(p.canBecomeKey)")
                        p.makeKey()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            log("focustest: asked for the keyboard while locked, key \(p.isKeyWindow)")
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
            return true
        }
        if args.contains("--tourlevels") {
            // Measures the welcome tour's sounds without playing any of them.
            for line in Sounds.tourLevels() { log("tourlevels: \(line)") }
            NSApp.terminate(nil)
            return true
        }
        if let i = args.firstIndex(of: "--chatshot"), i + 1 < args.count {
            // The chat with a reply being written, a quoted reply, and a picture open in the viewer. Uses made up
            // messages and a drawn picture, and never reads or writes saved chats. Writes OUT.png and OUT-zoom.png.
            let model = AssistantModel(forTesting: true)
            model.seeScreen = false
            var a = AssistantModel.Exchange(question: "What's the derivative of x squared?", answer: "It's 2x.\n\nThat comes from the power rule: bring the 2 down and drop the power by one.", withScreen: false, activity: nil)
            a.reactionsTold = true
            let b = AssistantModel.Exchange(question: "why does the power drop by one?", answer: "Because of how the limit expands.", withScreen: false, activity: nil,
                                            replyTo: ChatReply(text: "That comes from the **power rule**: bring the 2 down and drop the power by one.", mine: false, exchange: 0, part: 1))
            model.exchanges = [a, b]
            model.replyingTo = ChatReply(text: "Because of how the limit expands.", mine: false, exchange: 1, part: 0)
            let host = NSHostingView(rootView: AssistantView(model: model, onClose: {}).frame(width: 700, height: 680, alignment: .top))
            let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 700, height: 680), styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua); w.backgroundColor = NSColor(white: 0.25, alpha: 1)
            w.contentView = host; w.orderBack(nil)
            func snap(_ name: String) {
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: name))
                }
            }
            let pic = NSImage(size: NSSize(width: 1600, height: 1000), flipped: false) { r in
                NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.9, alpha: 1).setFill(); r.fill()
                NSColor.systemBlue.setStroke()
                for x in stride(from: 0, to: 1600, by: 100) { NSBezierPath.strokeLine(from: NSPoint(x: x, y: 0), to: NSPoint(x: x, y: 1000)) }
                for y in stride(from: 0, to: 1000, by: 100) { NSBezierPath.strokeLine(from: NSPoint(x: 0, y: y), to: NSPoint(x: 1600, y: y)) }
                NSColor.systemRed.setFill(); NSBezierPath(ovalIn: NSRect(x: 700, y: 400, width: 200, height: 200)).fill()
                return true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                snap(args[i + 1])
                let viewer = PictureViewer.shared
                // A pinch over a picture on screen opens it; a pinch elsewhere does nothing.
                viewer.mark(UUID(), rect: CGRect(x: 100, y: 100, width: 200, height: 150), item: .init(image: pic, fullSize: nil, open: nil, openLabel: "Open"))
                let missed = viewer.pinch(amount: 0.2, at: NSPoint(x: 600, y: 60), windowHeight: 680)
                let hit = viewer.pinch(amount: 0.2, at: NSPoint(x: 200, y: 680 - 170), windowHeight: 680)
                log("chatshot: pinch outside used=\(missed) open=\(viewer.item == nil ? false : missed), pinch on picture used=\(hit) open=\(viewer.item != nil)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard let s = viewer.scroll else { log("chatshot: viewer did not appear"); NSApp.terminate(nil); return }
                    log("chatshot: after opening pinch \(viewer.percent)% fit=\(s.fit) size=\(s.frame.size)")
                    snap(args[i + 1].replacingOccurrences(of: ".png", with: "-open.png"))
                    _ = viewer.pinch(amount: 1.0, at: NSPoint(x: 350, y: 300), windowHeight: 680)
                    let a = viewer.percent
                    _ = viewer.pinch(amount: -0.5, at: NSPoint(x: 350, y: 300), windowHeight: 680)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        log("chatshot: zoom in \(a)% then out \(viewer.percent)%")
                        s.zoom(by: 2, at: nil)
                        let shown = viewer
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            snap(args[i + 1].replacingOccurrences(of: ".png", with: "-zoom.png"))
                            s.showWhole()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                log("chatshot: fit button \(shown.percent)%")
                                shown.close()
                                log("chatshot: closed \(shown.item == nil)")
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
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
        if Whisper.ready { a.words = try? await Whisper.transcribe(url, voiced: Cutter.voiced(a)) { _ in }; a.engine = Whisper.engineTag }
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
