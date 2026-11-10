// How Ask Mercury hears and sees. Live listening transcribes what's playing and what you say on your Mac,
// and the screenshot is taken fresh each time you ask, leaving Mercury's own panel out of it.
// Kept apart from the chat so the private parts (sound and screen) are easy to find and check.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import CryptoKit
import ScreenCaptureKit
import Speech
import SwiftUI
import WebKit

// MARK: - Live listening

/// Mac audio and your microphone, mixed and transcribed on this Mac as they happen.
final class LiveListener: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Line: Identifiable { let id = UUID(); let text: String; let at: Date }

    var onChange: (() -> Void)?
    private(set) var lines: [Line] = []
    private(set) var live = ""
    private(set) var level: Float = 0

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "bubble.listener")
    private let lock = NSLock()
    private var macQ: [Float] = [], micQ: [Float] = []
    private var lastMac = Date.distantPast, lastMic = Date.distantPast
    private var converters: [String: AVAudioConverter] = [:]
    private let out16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var pump: DispatchSourceTimer?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskStarted = Date()
    private var running = false

    func start(mac: Bool, mic: Bool) async throws {
        guard !running else { return }
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else { throw Failure("Allow Speech Recognition for Mercury in System Settings → Privacy & Security.") }
        recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard recognizer?.supportsOnDeviceRecognition == true else { throw Failure("Turn on Dictation once in System Settings → Keyboard so macOS downloads on-device speech.") }

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw Failure("No display found.") }
        let cfg = SCStreamConfiguration()
        cfg.width = 2; cfg.height = 2                      // audio only; the picture is ignored
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.capturesAudio = mac
        cfg.excludesCurrentProcessAudio = true
        cfg.captureMicrophone = mic
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if mac { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if mic { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        try await s.startCapture()
        stream = s
        running = true
        queue.sync { newTask() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.mixAndFeed() }
        t.resume()
        pump = t
        log("assistant: listening (mac \(mac), mic \(mic))")
    }

    func stop() {
        guard running else { return }
        running = false
        pump?.cancel(); pump = nil
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
        queue.async { [self] in
            request?.endAudio()
            task?.cancel()
            commit()
            request = nil; task = nil
            lock.lock(); macQ = []; micQ = []; lock.unlock()
            level = 0
            notify()
        }
        log("assistant: stopped listening")
    }

    var isRunning: Bool { running }

    /// What was said in the last few minutes, oldest first.
    func recent(minutes: Double = 4) -> String {
        lock.lock(); defer { lock.unlock() }
        let since = Date().addingTimeInterval(-minutes * 60)
        let said = lines.filter { $0.at >= since }.map(\.text) + (live.isEmpty ? [] : [live])
        return said.joined(separator: "\n")
    }

    func clear() {
        lock.lock(); lines = []; live = ""; lock.unlock()
        notify()
    }

    // MARK: Audio in

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type != .screen, sb.isValid, let samples = to16k(sb, key: type == .audio ? "mac" : "mic") else { return }
        lock.lock()
        if type == .audio { macQ += samples; lastMac = Date(); if macQ.count > 32_000 { macQ.removeFirst(macQ.count - 32_000) } }
        else { micQ += samples; lastMic = Date(); if micQ.count > 32_000 { micQ.removeFirst(micQ.count - 32_000) } }
        lock.unlock()
    }

    func stream(_ s: SCStream, didStopWithError error: Error) {
        log("assistant: listening stopped: \(error.localizedDescription)")
        running = false
        notify()
    }

    private func to16k(_ sb: CMSampleBuffer, key: String) -> [Float]? {
        guard let fd = CMSampleBufferGetFormatDescription(sb) else { return nil }
        let inFormat = AVAudioFormat(cmAudioFormatDescription: fd)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return nil }
        inBuf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: inBuf.mutableAudioBufferList) == noErr else { return nil }
        let ck = key + "\(inFormat.sampleRate)-\(inFormat.channelCount)-\(inFormat.commonFormat.rawValue)-\(inFormat.isInterleaved)"
        if converters[ck] == nil { converters[ck] = AVAudioConverter(from: inFormat, to: out16k) }
        guard let conv = converters[ck] else { return nil }
        let cap = AVAudioFrameCount(Double(frames) * 16_000 / inFormat.sampleRate) + 32
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: out16k, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        guard err == nil, let p = outBuf.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength)))
    }

    /// Every 100 ms: mix what each source has, and hand it to the recognizer.
    private func mixAndFeed() {
        let n = 1600
        lock.lock()
        let now = Date()
        let macOn = now.timeIntervalSince(lastMac) < 0.5, micOn = now.timeIntervalSince(lastMic) < 0.5
        // A source that has stopped sending (nothing playing) counts as silence.
        guard (macOn && macQ.count >= n) || (micOn && micQ.count >= n) else { lock.unlock(); return }
        var mix = [Float](repeating: 0, count: n)
        for q in [0, 1] {
            let on = q == 0 ? macOn : micOn
            guard on else { continue }
            let take = min(n, q == 0 ? macQ.count : micQ.count)
            for i in 0..<take { mix[i] += q == 0 ? macQ[i] : micQ[i] }
            if q == 0 { macQ.removeFirst(take) } else { micQ.removeFirst(take) }
        }
        lock.unlock()
        var peak: Float = 0
        for i in 0..<n { mix[i] = max(-1, min(1, mix[i])); peak = max(peak, abs(mix[i])) }
        level = peak
        guard let buf = AVAudioPCMBuffer(pcmFormat: out16k, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        mix.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: n) }
        request?.append(buf)
        // Start a fresh recognition every 50 s so no single request grows too long.
        if Date().timeIntervalSince(taskStarted) > 50 {
            request?.endAudio()
            newTask()
        }
    }

    // MARK: Recognition (runs on `queue`)

    private func newTask() {
        guard running, let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        request = req
        taskStarted = Date()
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                if let r = result {
                    self.update(r.bestTranscription.formattedString)
                    if r.isFinal { self.commit() }
                }
                if error != nil, self.request === req {
                    self.commit()
                    self.queue.asyncAfter(deadline: .now() + 0.3) { if self.request === req { self.newTask() } }
                }
            }
        }
    }

    /// On-device recognition starts over after a pause; keep what was said before it.
    private func update(_ text: String) {
        lock.lock()
        let cur = live
        if !cur.isEmpty, text.count < cur.count / 2, !cur.lowercased().hasPrefix(text.lowercased().prefix(4)) {
            lines.append(Line(text: cur, at: Date()))
        }
        live = text
        lock.unlock()
        notify()
    }

    private func commit() {
        lock.lock()
        if !live.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(Line(text: live, at: Date())) }
        live = ""
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        lock.unlock()
        notify()
    }

    private func notify() { DispatchQueue.main.async { self.onChange?() } }

    struct Failure: LocalizedError { let m: String; init(_ m: String) { self.m = m }; var errorDescription: String? { m } }
}

// MARK: - Seeing the screen

enum ScreenGrab {
    /// A JPEG of the display under the mouse, without Mercury's own panels.
    static func jpeg(excluding windowNumbers: [Int]) async -> Data? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let screen = NSScreen.underMouse
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) ?? content.displays.first else { return nil }
            let hide = content.windows.filter { windowNumbers.contains(Int($0.windowID)) }
            let cfg = SCStreamConfiguration()
            let scale = min(1, 1568 / CGFloat(max(display.width, display.height)))
            // About 1568 px on the long side: sharp enough to read, small enough to send quickly.
            cfg.width = Int(CGFloat(display.width) * scale)
            cfg.height = Int(CGFloat(display.height) * scale)
            cfg.showsCursor = true
            let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: hide), configuration: cfg)
            return NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.72])
        } catch {
            log("assistant: screenshot failed: \(error.localizedDescription)")
            return nil
        }
    }
}
