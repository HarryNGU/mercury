// Screen capture (ScreenCaptureKit) + mic (MicCapture) written to an MP4 with AVAssetWriter.

import AppKit
import AVFoundation
import ScreenCaptureKit

/// What to record. Area rects are in the display's own points, top-left origin.
enum CaptureSource {
    case screenUnderMouse
    case display(CGDirectDisplayID)
    case window(CGWindowID, String)
    case app(pid_t, String)
    case area(CGDirectDisplayID, CGRect)
    case croppedWindow(CGWindowID, CGFloat, String)  // window minus a top inset (Chrome's toolbar)

    /// A whole display, where you move between apps and desktops while recording.
    var isWholeScreen: Bool {
        switch self {
        case .screenUnderMouse, .display: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .screenUnderMouse: return "Entire screen"
        case .display(let id): return NSScreen.with(displayID: id)?.localizedName ?? "Display"
        case .window(_, let title): return title
        case .app(_, let name): return "\(name) (all windows)"
        case .area(_, let r): return "Custom area \(Int(r.width)) × \(Int(r.height))"
        case .croppedWindow(_, _, let title): return "Chrome tab: \(title)"
        }
    }
}

/// A sample buffer passed from the thread that made it to the writer queue, which then owns it.
private struct SampleHandoff: @unchecked Sendable { let buffer: CMSampleBuffer }

struct RecordError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Two kinds of state live here, each owned by one thread, which is why the class can be shared
/// across threads (`@unchecked Sendable`) without locks:
/// the capture controls (`stream`, `windowTarget`, `overlays`, `recordedRect`, `url`) belong to the
/// main actor, so `start`, `stop`, `setOverlays` and the mic revival never race each other;
/// the writer state (the writer, its inputs, timestamps, pause) is only touched on `queue`.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let mic = MicCapture()
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var micIn: AVAssetWriterInput?
    private var sysIn: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "bubble.writer")
    private var sessionStarted = false
    private var lastVideo: CMSampleBuffer?
    /// The latest screen frame as captured, so it can be written again blurred if a check spots something late.
    private var lastRaw: CMSampleBuffer?
    private var lastVideoPTS = CMTime.invalid
    private var lastTime = CMTime.invalid
    private(set) var url: URL?

    var onFinish: ((URL?) -> Void)?
    var onMicLevel: ((Float) -> Void)? {
        get { mic.onLevel }
        set { mic.onLevel = newValue }
    }
    var onError: ((Error) -> Void)?

    /// The region being recorded in AppKit screen coordinates (used to place the camera bubble).
    private(set) var recordedRect: NSRect?

    /// A window or tab recording takes only that window (plus the camera bubble), so Mercury's own
    /// panels have to be added to it by name when you've chosen to show them.
    private var windowTarget: (window: SCWindow, display: SCDisplay, extras: [SCWindow])?
    /// Blurs passwords, emails, card numbers and the like as they're recorded (Settings → Recording).
    private var redactor: Redactor?
    private var overlays: [Int] = []

    @MainActor func start(source: CaptureSource, excluding: [Int], bubble: [Int], mic useMic: Bool,
               noiseSuppression: Bool, systemAudio: Bool) async throws {
        windowTarget = nil
        overlays = []
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let windowsByNumber = { (ns: [Int]) in content.windows.filter { ns.contains(Int($0.windowID)) } }
        let excluded = windowsByNumber(excluding)
        let bubbleWindows = windowsByNumber(bubble)

        // With private details blurred, password managers aren't recorded at all. (Mercury's own pill is
        // already invisible to every capture, so excluding whole apps loses nothing.)
        let hiddenApps = Settings.blurPrivate ? content.applications.filter { Redactor.passwordApps.contains($0.bundleIdentifier) } : []
        func screenFilter(_ d: SCDisplay) -> SCContentFilter {
            hiddenApps.isEmpty ? SCContentFilter(display: d, excludingWindows: excluded)
                               : SCContentFilter(display: d, excludingApplications: hiddenApps, exceptingWindows: [])
        }
        func display(id: CGDirectDisplayID) -> SCDisplay? { content.displays.first { $0.displayID == id } }
        func display(containing r: CGRect) -> SCDisplay? {
            content.displays.max { a, b in
                let ia = a.frame.intersection(r), ib = b.frame.intersection(r)
                return ia.width * ia.height < ib.width * ib.height
            }
        }

        var filter: SCContentFilter
        var scDisplay: SCDisplay
        var crop: CGRect?  // display-local points, top-left origin

        switch source {
        case .screenUnderMouse, .display:
            var id = NSScreen.underMouse.displayID
            if case .display(let d) = source { id = d }
            guard let d = display(id: id) ?? content.displays.first else { throw RecordError(message: "No display found.") }
            scDisplay = d
            filter = screenFilter(d)

        case .area(let id, let rect):
            guard let d = display(id: id) else { throw RecordError(message: "That display is no longer connected.") }
            scDisplay = d
            filter = screenFilter(d)
            crop = rect

        case .window(let wid, _), .croppedWindow(let wid, _, _):
            guard let w = content.windows.first(where: { $0.windowID == wid }) else {
                throw RecordError(message: "That window is closed or hidden. Pick it again.")
            }
            guard let d = display(containing: w.frame) else { throw RecordError(message: "No display found.") }
            scDisplay = d
            // Record only that window (plus the camera bubble), cropped to the window's frame.
            filter = SCContentFilter(display: d, including: [w] + bubbleWindows)
            windowTarget = (w, d, bubbleWindows)
            var frame = w.frame
            if case .croppedWindow(_, let inset, _) = source, inset < frame.height - 50 {
                frame.origin.y += inset
                frame.size.height -= inset
            }
            crop = frame.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
                .intersection(CGRect(origin: .zero, size: d.frame.size))

        case .app(let pid, _):
            guard let a = content.applications.first(where: { $0.processID == pid }) else {
                throw RecordError(message: "That app has quit. Pick it again.")
            }
            let appWindows = content.windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen }
            let biggest = appWindows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            guard let d = (biggest.flatMap { display(containing: $0.frame) }) ?? content.displays.first else {
                throw RecordError(message: "No display found.")
            }
            scDisplay = d
            var apps = [a]
            if let me = content.applications.first(where: { $0.processID == getpid() }) { apps.append(me) }
            filter = SCContentFilter(display: d, including: apps, exceptingWindows: excluded)
        }

        let region = crop ?? CGRect(origin: .zero, size: scDisplay.frame.size)
        recordedRect = appKitRect(fromGlobalTopLeft: region.offsetBy(dx: scDisplay.frame.minX, dy: scDisplay.frame.minY))

        // Output size: native pixels, capped for H.264.
        let scale = CGFloat(filter.pointPixelScale)
        var w = region.width * scale, h = region.height * scale
        let maxW: CGFloat = 3840, maxH: CGFloat = 2160
        let fit = min(1, maxW / w, maxH / h)
        w = (w * fit).rounded()
        h = (h * fit).rounded()
        let width = max(2, Int(w) & ~1), height = max(2, Int(h) & ~1)

        let cfg = SCStreamConfiguration()
        if let crop { cfg.sourceRect = crop }
        cfg.width = width
        cfg.height = height
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.showsCursor = true
        cfg.queueDepth = 8
        cfg.capturesAudio = systemAudio
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2

        // Writer
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = Settings.folder.appendingPathComponent("Mercury \(fmt.string(from: Date())).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let bitrate = max(3_000_000, Int(Double(width * height) * 60 * 0.04))
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 120,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoIn.expectsMediaDataInRealTime = true
        writer.add(videoIn)

        func audioInput(channels: Int) -> AVAssetWriterInput {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
            ])
            i.expectsMediaDataInRealTime = true
            writer.add(i)
            return i
        }
        let micIn = useMic ? audioInput(channels: 1) : nil
        let sysIn = systemAudio ? audioInput(channels: 2) : nil
        guard writer.startWriting() else { throw writer.error ?? RecordError(message: "Could not create the video file.") }

        queue.sync {
            self.writer = writer
            self.videoIn = videoIn
            self.micIn = micIn
            self.sysIn = sysIn
            self.sessionStarted = false
            self.lastVideo = nil
            self.lastTime = .invalid
            self.micNext = .invalid
            self.lastRaw = nil
            self.lastVideoPTS = .invalid
            self.redactor = Settings.blurPrivate ? Redactor(queue: queue) : nil
            self.redactor?.onNewFinds = { [weak self] in self?.rewriteStill() }
        }
        self.url = url

        // Start the mic first: voice processing takes a moment to warm up, and video only
        // begins with the first screen frame, so the audio is ready from the first second.
        if useMic {
            mic.onSampleBuffer = { [weak self] sb in
                // The mic hands each buffer over and never touches it again, so passing it to the writer queue is safe.
                let handoff = SampleHandoff(buffer: sb)
                self?.queue.async { self?.append(handoff.buffer, to: self?.micIn) }
            }
            do { try await mic.start(noiseSuppression: noiseSuppression) } catch {
                log("mic start failed (\(error)); retrying plain mic")
                try await mic.start(noiseSuppression: false)
            }
        }
        if let r = queue.sync(execute: { redactor }) { await Task.detached { r.warmUp() }.value }
        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        try await stream.startCapture()
        self.stream = stream

        log("recording \(source.label) at \(width)×\(height), \(bitrate / 1000) kbps → \(url.lastPathComponent)")
    }

    private var micRestarting = false

    /// Adds Mercury's own panels (Ask Mercury) to a window or tab recording, or takes them out again.
    /// Screen, area and app recordings follow each window's own sharing setting instead.
    @MainActor func setOverlays(_ numbers: [Int]) {
        guard let stream, let t = windowTarget, numbers != overlays else { return }
        overlays = numbers
        Task {
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let extra = content?.windows.filter { numbers.contains(Int($0.windowID)) } ?? []
            do { try await stream.updateContentFilter(SCContentFilter(display: t.display, including: [t.window] + t.extras + extra)) }
            catch { log("couldn't update what's recorded: \(error)") }
        }
    }

    /// Brings the mic back if it stopped delivering sound mid-recording. Called a few times a second.
    @MainActor func reviveMicIfNeeded() {
        guard stream != nil, !micRestarting, mic.isStalled(after: 2) else { return }
        micRestarting = true
        log("mic: no sound for 2 s, starting it again")
        Task { @MainActor in
            do { try await mic.restart() } catch { log("mic restart failed: \(error)") }
            micRestarting = false
        }
    }

    func stallMicForTesting() { mic.stallForTesting() }

    @MainActor func stop(discarding: Bool) async {
        if let r = queue.sync(execute: { redactor }) { log("blur: \(r.spotted) private detail\(r.spotted == 1 ? "" : "s") blurred") }
        mic.stop()
        if let stream { try? await stream.stopCapture() }
        stream = nil
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { self.finishWriting(discarding: discarding) { done.resume() } }
        }
    }

    // MARK: Pause

    private var paused = false
    private var pausedAt: CMTime?
    private var pauseOffset = CMTime.zero  // total time spent paused, removed from timestamps

    /// While paused, frames and audio are dropped; afterwards timestamps are shifted back by
    /// the paused time so the video plays straight through without a gap.
    func setPaused(_ pause: Bool) {
        queue.async {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            if pause, !self.paused {
                self.paused = true
                self.pausedAt = now
            } else if !pause, self.paused, let at = self.pausedAt {
                self.pauseOffset = self.pauseOffset + (now - at)
                self.paused = false
                self.pausedAt = nil
            }
            log(pause ? "paused" : "resumed (paused total \(String(format: "%.1f", self.pauseOffset.seconds))s)")
        }
    }

    private func shifted(_ sb: CMSampleBuffer) -> CMSampleBuffer {
        guard pauseOffset > .zero else { return sb }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sb }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        for i in infos.indices {
            infos[i].presentationTimeStamp = infos[i].presentationTimeStamp - pauseOffset
            if infos[i].decodeTimeStamp.isValid { infos[i].decodeTimeStamp = infos[i].decodeTimeStamp - pauseOffset }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                              sampleTimingArray: &infos, sampleBufferOut: &out)
        return out ?? sb
    }

    // MARK: Writing (all on `queue`)

    /// A check spotted something private in a frame that was already written. Write the latest frame
    /// again, blurred, a moment after the last one, so a still screen doesn't keep showing it.
    private func rewriteStill() {
        guard sessionStarted, !paused, writer?.status == .writing, let raw = lastRaw, let redactor,
              let videoIn, videoIn.isReadyForMoreMediaData, lastVideoPTS.isValid else { return }
        let at = lastVideoPTS + CMTime(value: 1, timescale: 600)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: at, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: redactor.blurOnly(raw), sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &copy)
        guard let copy else { return }
        videoIn.append(copy)
        lastVideo = copy
        lastVideoPTS = at
        if !lastTime.isValid || at > lastTime { lastTime = at }
    }

    private func append(_ raw: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard sessionStarted, !paused, let input, input.isReadyForMoreMediaData else { return }
        let sb = shifted(raw)
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard let start = startTime, pts >= start else { return }
        if input === micIn {
            // If the mic was off for a moment (the Mac began to sleep, say), fill the gap with silence
            // so your voice stays in time with the picture.
            if micNext.isValid, (pts - micNext).seconds > 0.1 {
                log("mic: filling \(String(format: "%.1f", (pts - micNext).seconds)) s gap with silence")
                var t = micNext
                while (pts - t).seconds > 0.01 {
                    let chunk = min(1, (pts - t).seconds)
                    guard input.isReadyForMoreMediaData, let gap = MicCapture.silence(at: t, seconds: chunk) else { break }
                    input.append(gap)
                    t = t + CMTime(seconds: chunk, preferredTimescale: CMTimeScale(MicCapture.sampleRate))
                }
            }
            micNext = pts + CMTime(value: CMTimeValue(CMSampleBufferGetNumSamples(sb)), timescale: CMTimeScale(MicCapture.sampleRate))
        }
        input.append(sb)
        let end = CMTimeAdd(pts, CMSampleBufferGetDuration(sb))
        if !lastTime.isValid || end > lastTime { lastTime = end }
    }

    private var startTime: CMTime?
    private var micNext = CMTime.invalid  // where the next mic sound should start (writer queue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, let writer, writer.status == .writing else { return }
        switch type {
        case .screen:
            guard let info = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            if !sessionStarted {
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                writer.startSession(atSourceTime: pts)
                startTime = pts
                sessionStarted = true
            }
            if paused { return }
            lastRaw = sb
            if let videoIn, videoIn.isReadyForMoreMediaData {
                let sb = shifted(redactor?.process(sb) ?? sb)
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                // A frame written again after a late find can sit just after this one; never go backwards.
                if lastVideoPTS.isValid, pts <= lastVideoPTS { return }
                videoIn.append(sb)
                lastVideo = sb
                lastVideoPTS = pts
                if !lastTime.isValid || pts > lastTime { lastTime = pts }
            }
        case .audio:
            append(sb, to: sysIn)
        default:
            break
        }
    }

    private func finishWriting(discarding: Bool, then done: @escaping () -> Void) {
        guard let writer else { done(); return }
        let url = writer.outputURL
        let hadSystemAudio = sysIn != nil && micIn != nil
        if sessionStarted, writer.status == .writing {
            // Repeat the last frame at the end so a still screen doesn't cut the video short.
            var now = CMClockGetTime(CMClockGetHostTimeClock()) - pauseOffset
            if paused, let at = pausedAt { now = at - pauseOffset }  // stopped while paused
            if let last = lastVideo, let videoIn, videoIn.isReadyForMoreMediaData {
                var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
                var copy: CMSampleBuffer?
                CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: last, sampleTimingEntryCount: 1,
                                                      sampleTimingArray: &timing, sampleBufferOut: &copy)
                if let copy { videoIn.append(copy) }
                lastTime = max(lastTime, now)
            }
            [videoIn, micIn, sysIn].forEach { $0?.markAsFinished() }
            writer.endSession(atSourceTime: lastTime)
            writer.finishWriting { [self] in
                let ok = writer.status == .completed
                log("writer finished: status \(writer.status.rawValue) \(writer.error.map { "\($0)" } ?? "")")
                self.reset()
                if discarding || !ok {
                    try? FileManager.default.removeItem(at: url)
                    DispatchQueue.main.async {
                        if !ok && !discarding { self.onError?(writer.error ?? RecordError(message: "The video could not be saved.")) }
                        else { self.onFinish?(nil) }
                    }
                    done()
                } else if hadSystemAudio {
                    Self.mixDownAudio(url) { DispatchQueue.main.async { self.onFinish?(url) }; done() }
                } else {
                    DispatchQueue.main.async { self.onFinish?(url) }
                    done()
                }
            }
        } else {
            writer.cancelWriting()
            reset()
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                if discarding { self.onFinish?(nil) }
                else { self.onError?(RecordError(message: "Nothing was captured. Is the window visible on screen?")) }
            }
            done()
        }
    }

    private func reset() {
        writer = nil; videoIn = nil; micIn = nil; sysIn = nil
        sessionStarted = false; startTime = nil; lastVideo = nil; lastRaw = nil; lastVideoPTS = .invalid; lastTime = .invalid
        paused = false; pausedAt = nil; pauseOffset = .zero
    }

    /// Mic and system audio are recorded as two tracks; most players only play the first,
    /// so merge them into one track (video is copied untouched).
    private static func mixDownAudio(_ url: URL, done: @escaping () -> Void) {
        Task {
            let asset = AVURLAsset(url: url)
            do {
                let comp = AVMutableComposition()
                let duration = try await asset.load(.duration)
                let range = CMTimeRange(start: .zero, duration: duration)
                for track in try await asset.loadTracks(withMediaType: .video) {
                    let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                    try t?.insertTimeRange(range, of: track, at: .zero)
                }
                for track in try await asset.loadTracks(withMediaType: .audio) {
                    let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    try t?.insertTimeRange(range, of: track, at: .zero)
                }
                let tmp = url.deletingLastPathComponent().appendingPathComponent(".mixing-\(UUID().uuidString).mp4")
                guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { done(); return }
                try await export.export(to: tmp, as: .mp4)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
                log("mixed mic + system audio into one track")
            } catch {
                log("audio mixdown failed, keeping two tracks: \(error)")
            }
            done()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped with error: \(error)")
        mic.stop()
        queue.async { self.finishWriting(discarding: false) { } }
        DispatchQueue.main.async {
            self.stream = nil  // capture controls belong to the main actor
            self.onError?(error)
        }
    }
}
