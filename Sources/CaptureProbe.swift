// Test only (`--capturetest`): counts the frames ScreenCaptureKit sends for one of Mercury's own nearly
// invisible windows in a few situations, so we know which filter keeps recording when a window stops being
// visible on the current screen (another Space, covered, moved away). Keeps no pictures.

import AppKit
import ScreenCaptureKit

@MainActor
enum CaptureProbe {
    private final class Counter: NSObject, SCStreamOutput, SCStreamDelegate {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        var snapshot: [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }
        func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen else { return }
            var key = "nostatus"
            if let info = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let raw = info.first?[.status] as? Int, let st = SCFrameStatus(rawValue: raw) {
                key = ["complete", "idle", "blank", "suspended", "started", "stopped"][min(st.rawValue, 5)]
            }
            lock.lock(); counts[key, default: 0] += 1; lock.unlock()
        }
        func stream(_ s: SCStream, didStopWithError e: Error) { log("capturetest: stream stopped: \(e)") }
    }

    static func run() async {
        func make(_ r: NSRect) -> NSWindow {
            let w = NSWindow(contentRect: r, styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.backgroundColor = .systemTeal
            w.alphaValue = 0.02
            w.ignoresMouseEvents = true
            w.orderFrontRegardless()
            return w
        }
        let visible = make(NSRect(x: 2, y: 2, width: 80, height: 80))
        let away = make(NSRect(x: -6000, y: -6000, width: 80, height: 80))
        try? await Task.sleep(nanoseconds: 500_000_000)
        await probe("visible, display filter", visible, independent: false)
        await probe("visible, window filter", visible, independent: true)
        await probe("off every display, display filter", away, independent: false)
        await probe("off every display, window filter", away, independent: true)
        await probe("hidden part way, display filter", visible, independent: false) { visible.orderOut(nil) }
        visible.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 300_000_000)
        await probe("hidden part way, window filter", visible, independent: true) { visible.orderOut(nil) }
        // The same window moved onto each Space you aren't looking at (another desktop, or a full screen app's
        // Space), the way a full screen Chrome window is when you swipe away from it.
        let cid = CGSMainConnectionID()
        let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] ?? []
        let current = Set(displays.compactMap { ($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int })
        let others = displays.flatMap { ($0["Spaces"] as? [[String: Any]]) ?? [] }
            .compactMap { sp -> (Int, Int)? in
                guard let id = sp["ManagedSpaceID"] as? Int, !current.contains(id) else { return nil }
                return (id, sp["type"] as? Int ?? -1)
            }
        log("capturetest: current Space \(current.sorted()), others \(others.map { "\($0.0) type \($0.1)" })")
        let wid = [NSNumber(value: visible.windowNumber)] as CFArray
        for (space, type) in others.prefix(3) {
            let here = current.map { NSNumber(value: $0) } as CFArray
            CGSAddWindowsToSpaces(cid, wid, [NSNumber(value: space)] as CFArray)
            CGSRemoveWindowsFromSpaces(cid, wid, here)
            try? await Task.sleep(nanoseconds: 400_000_000)
            await probe("on Space \(space) type \(type), display filter", visible, independent: false)
            await probe("on Space \(space) type \(type), window filter", visible, independent: true)
            CGSAddWindowsToSpaces(cid, wid, here)
            CGSRemoveWindowsFromSpaces(cid, wid, [NSNumber(value: space)] as CFArray)
        }
        visible.close(); away.close()
    }

    @_silgen_name("CGSMainConnectionID") private static func CGSMainConnectionID() -> Int32
    @_silgen_name("CGSCopyManagedDisplaySpaces") private static func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray
    @_silgen_name("CGSAddWindowsToSpaces") private static func CGSAddWindowsToSpaces(_ cid: Int32, _ windows: CFArray, _ spaces: CFArray)
    @_silgen_name("CGSRemoveWindowsFromSpaces") private static func CGSRemoveWindowsFromSpaces(_ cid: Int32, _ windows: CFArray, _ spaces: CFArray)

    /// `--notabtest`: records one of Mercury's own nearly invisible windows with the real recorder into a temporary
    /// folder three times: left where it is (a normal video must come out); with no pictures arriving while the
    /// window is on screen (Mercury tries capturing the window by itself, then warns); and with no pictures while the
    /// window has moved to a Space you aren't looking at (Mercury warns straight away instead of saving nothing).
    static func noPictureTest() async {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mercury-notabtest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let w = NSWindow(contentRect: NSRect(x: 2, y: 2, width: 120, height: 120), styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .systemTeal
        w.alphaValue = 0.02
        w.ignoresMouseEvents = true
        w.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let cid = CGSMainConnectionID()
        let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] ?? []
        let current = displays.compactMap { ($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int }
        let other = displays.flatMap { ($0["Spaces"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["ManagedSpaceID"] as? Int }.first { !current.contains($0) }
        let wid = [NSNumber(value: w.windowNumber)] as CFArray

        for (drop, moveAway) in [(false, false), (true, false), (true, true)] {
            let r = Recorder()
            var noPicture: Date?
            var finishedURL: URL??
            r.onNoPicture = { _ in noPicture = Date() }
            r.onFinish = { finishedURL = .some($0) }
            r.onError = { log("notabtest: error \($0.localizedDescription)") }
            r.dropsFramesForTesting = drop
            let began = Date()
            do {
                try await r.start(source: .window(CGWindowID(w.windowNumber), "test window"), excluding: [], bubble: [],
                                  mic: false, noiseSuppression: false, systemAudio: false, folder: tmp)
                if moveAway, let other {
                    CGSAddWindowsToSpaces(cid, wid, [NSNumber(value: other)] as CFArray)
                    CGSRemoveWindowsFromSpaces(cid, wid, current.map { NSNumber(value: $0) } as CFArray)
                }
            } catch {
                log("notabtest: start failed: \(error.localizedDescription)")
                CGSAddWindowsToSpaces(cid, wid, current.map { NSNumber(value: $0) } as CFArray)
                if let other { CGSRemoveWindowsFromSpaces(cid, wid, [NSNumber(value: other)] as CFArray) }
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            for _ in 0..<80 where noPicture == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            await r.stop(discarding: noPicture != nil)
            for _ in 0..<30 where finishedURL == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            let saved = (finishedURL ?? nil).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            log("notabtest: \(!drop ? "normal" : moveAway ? "no pictures, window on another Space" : "no pictures, window on screen"): no picture warning \(noPicture.map { String(format: "after %.1f s", $0.timeIntervalSince(began)) } ?? "never"), video saved \(saved)")
            if moveAway {
                CGSAddWindowsToSpaces(cid, wid, current.map { NSNumber(value: $0) } as CFArray)
                if let other { CGSRemoveWindowsFromSpaces(cid, wid, [NSNumber(value: other)] as CFArray) }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        w.close()
        try? FileManager.default.removeItem(at: tmp)
    }

    private static func probe(_ name: String, _ window: NSWindow, independent: Bool, midway: (() -> Void)? = nil) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let w = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }),
                  let d = content.displays.first else { log("capturetest: \(name): window not listed"); return }
            let filter = independent ? SCContentFilter(desktopIndependentWindow: w) : SCContentFilter(display: d, including: [w])
            let cfg = SCStreamConfiguration()
            cfg.width = 160; cfg.height = 160
            if !independent { cfg.sourceRect = w.frame.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY) }
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            let c = Counter()
            let s = SCStream(filter: filter, configuration: cfg, delegate: c)
            try s.addStreamOutput(c, type: .screen, sampleHandlerQueue: DispatchQueue(label: "bubble.capturetest"))
            try await s.startCapture()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let first = c.snapshot
            midway?()
            try await Task.sleep(nanoseconds: 1_500_000_000)
            try await s.stopCapture()
            log("capturetest: \(name) (listed on screen \(w.isOnScreen)): first second \(first), in all \(c.snapshot)")
        } catch {
            log("capturetest: \(name): \(error.localizedDescription)")
        }
    }
}
