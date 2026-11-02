// Turns a recording into short, sharp reels: finds the pauses from the audio level, cuts them
// out, and lays the screen out for Original, 1:1, 9:16 and 16:9 with big captions. Everything here runs
// on the Mac (Apple's on-device speech recognition for captions). The edit is a plan of numbers
// (see EditPlan) that the editor's sliders and the Claude chat both change.

import AppKit
import AVFoundation
import CoreImage
import Speech

// MARK: - The edit

struct TimeSpan: Codable, Equatable {
    var start: Double
    var end: Double
    var length: Double { end - start }
}

/// The same four shapes Instagram offers when you post: the recording's own shape, square,
/// tall (Reels, TikTok, Shorts) and wide (YouTube, LinkedIn, X).
enum ReelSize: String, CaseIterable, Codable, Identifiable {
    case original, square, vertical, landscape
    var id: String { rawValue }
    var ratio: String { switch self { case .original: "Original"; case .square: "1:1"; case .vertical: "9:16"; case .landscape: "16:9" } }
    var icon: String {
        switch self {
        case .original: "photo"
        case .square: "square"
        case .vertical: "rectangle.portrait"
        case .landscape: "rectangle"
        }
    }
    var use: String {
        switch self {
        case .original: "As recorded"
        case .square: "Feed posts"
        case .vertical: "Reels, TikTok, Shorts"
        case .landscape: "YouTube, LinkedIn, X"
        }
    }
    /// Output size in pixels. Original keeps the recording's shape, up to 1920 wide.
    func render(source: CGSize) -> CGSize {
        switch self {
        case .square: return CGSize(width: 1080, height: 1080)
        case .vertical: return CGSize(width: 1080, height: 1920)
        case .landscape: return CGSize(width: 1920, height: 1080)
        case .original:
            guard source.width > 0, source.height > 0 else { return CGSize(width: 1920, height: 1080) }
            let scale = min(1, 1920 / source.width)
            func even(_ v: CGFloat) -> CGFloat { (v * scale / 2).rounded() * 2 }
            return CGSize(width: even(source.width), height: even(source.height))
        }
    }
    var fileTag: String { switch self { case .original: "original"; case .square: "1x1"; case .vertical: "9x16"; case .landscape: "16x9" } }
}

struct EditPlan: Codable, Equatable {
    /// Silence left between phrases, in seconds. Longer silences are cut down to this. nil = keep pauses.
    var maxPause: Double? = 0.25
    /// Parts of the original removed on request (seconds in the original video).
    var removed: [TimeSpan] = []
    /// Parts always kept, even if silent (for example a demo with no talking).
    var kept: [TimeSpan] = []
    var speed: Double = 1.0
    var captions = true
    var captionPosition = "bottom"   // top, middle, bottom
    /// 1 = the whole recording fits the frame; higher crops in towards `focus`.
    var zoom: Double = 1.0
    var focusX: Double = 0.5         // 0 left … 1 right
    var focusY: Double = 0.5         // 0 top … 1 bottom
    var title: String
    // The studio (see Studio.swift). Times are seconds in the original.
    var splits: [Double] = []
    var clipSpeeds: [Ranged] = []
    var clipVolumes: [Ranged] = []
    /// A clip's own mix of the two sound tracks: your microphone, and the computer's sound.
    var clipMic: [Ranged] = []
    var clipSys: [Ranged] = []
    var texts: [TextItem] = []
    var zooms: [ZoomItem] = []
    var images: [ImageItem] = []
    var videos: [VideoItem] = []
    var blurs: [BlurItem] = []
    var music: MusicTrack?
    /// The captions' words once you've corrected them; nil = as transcribed.
    var words: [Word]?
    var captionStyle = CaptionStyle()
    var canvas = CanvasStyle()
    var look = Look()
    var audio = AudioSettings()
    var progressBar: ProgressBar?
}

// Every field falls back to its default, so edits saved by an older Bubble still open.
extension EditPlan {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(title: c.v(.title, "Reel"))
        let z = self
        maxPause = c.v(.maxPause, z.maxPause); removed = c.v(.removed, z.removed); kept = c.v(.kept, z.kept)
        speed = c.v(.speed, z.speed); captions = c.v(.captions, z.captions); captionPosition = c.v(.captionPosition, z.captionPosition)
        zoom = c.v(.zoom, z.zoom); focusX = c.v(.focusX, z.focusX); focusY = c.v(.focusY, z.focusY)
        splits = c.v(.splits, z.splits); clipSpeeds = c.v(.clipSpeeds, z.clipSpeeds); clipVolumes = c.v(.clipVolumes, z.clipVolumes)
        clipMic = c.v(.clipMic, z.clipMic); clipSys = c.v(.clipSys, z.clipSys)
        texts = c.v(.texts, z.texts); zooms = c.v(.zooms, z.zooms); images = c.v(.images, z.images); videos = c.v(.videos, z.videos); blurs = c.v(.blurs, z.blurs); music = c.v(.music, z.music)
        words = c.v(.words, z.words); captionStyle = c.v(.captionStyle, z.captionStyle); canvas = c.v(.canvas, z.canvas)
        look = c.v(.look, z.look); audio = c.v(.audio, z.audio); progressBar = c.v(.progressBar, z.progressBar)
    }

}

struct Word: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
}

/// What Bubble learns from a recording once, then keeps: audio loudness every 20 ms and the words.
struct Analysis: Codable {
    var duration: Double
    var hop: Double
    var levels: [Float]       // dBFS per hop; empty when there's no sound
    var words: [Word]?        // nil until transcribed
    var engine: String?       // "whisper" or "apple": who wrote the words
}

// MARK: - Finding what to keep

enum Cutter {
    /// The parts of the original to keep, in order.
    static func spans(_ a: Analysis, _ p: EditPlan) -> [TimeSpan] {
        var keep: [TimeSpan]
        // 0 (or none) keeps every pause. Saved as 0, since an empty value reads back as the default.
        if let maxPause = p.maxPause, maxPause > 0, !a.levels.isEmpty {
            keep = voiced(a).map { TimeSpan(start: $0.start - maxPause / 2, end: $0.end + maxPause / 2) }
            keep = merge(keep + p.kept)
            if keep.isEmpty { keep = [TimeSpan(start: 0, end: a.duration)] }
        } else {
            keep = [TimeSpan(start: 0, end: a.duration)]
        }
        keep = keep.map { TimeSpan(start: max(0, $0.start), end: min(a.duration, $0.end)) }
        for r in p.removed { keep = keep.flatMap { subtract(r, from: $0) } }
        return keep.filter { $0.length > 0.08 }
    }

    /// Stretches where someone is talking: louder than the room by a margin.
    static func voiced(_ a: Analysis) -> [TimeSpan] {
        let sorted = a.levels.sorted()
        guard !sorted.isEmpty else { return [] }
        let floor = sorted[Int(Double(sorted.count) * 0.15)]
        let loud = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let threshold = min(max(floor + 10, -55), loud - 8)
        var runs: [TimeSpan] = []
        var start: Int?
        for (i, l) in a.levels.enumerated() {
            if l > threshold { if start == nil { start = i } } else if let s = start {
                runs.append(TimeSpan(start: Double(s) * a.hop, end: Double(i) * a.hop)); start = nil
            }
        }
        if let s = start { runs.append(TimeSpan(start: Double(s) * a.hop, end: Double(a.levels.count) * a.hop)) }
        // Join breaths inside a phrase, then drop clicks and bumps.
        var joined: [TimeSpan] = []
        for r in runs {
            if let last = joined.last, r.start - last.end < 0.18 { joined[joined.count - 1].end = r.end } else { joined.append(r) }
        }
        return joined.filter { $0.length >= 0.15 }
    }

    static func merge(_ spans: [TimeSpan]) -> [TimeSpan] {
        var out: [TimeSpan] = []
        for s in spans.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start <= last.end { out[out.count - 1].end = max(last.end, s.end) } else { out.append(s) }
        }
        return out
    }

    static func subtract(_ r: TimeSpan, from s: TimeSpan) -> [TimeSpan] {
        guard r.end > s.start, r.start < s.end else { return [s] }
        var out: [TimeSpan] = []
        if r.start > s.start { out.append(TimeSpan(start: s.start, end: r.start)) }
        if r.end < s.end { out.append(TimeSpan(start: r.end, end: s.end)) }
        return out
    }

    /// Where an original time lands in the edit (nil if it was cut).
    static func outputTime(_ t: Double, spans: [TimeSpan], speed: Double) -> Double? {
        var offset = 0.0
        for s in spans {
            if t >= s.start && t <= s.end { return (offset + t - s.start) / speed }
            offset += s.length
        }
        return nil
    }
}

// MARK: - Listening to the recording

enum Analyzer {
    static let hop = 0.02
    private static let format: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    /// Loudness every 20 ms, from the first audio track (the microphone).
    static func levels(of url: URL) async throws -> Analysis {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return Analysis(duration: duration, hop: hop, levels: [], words: [])
        }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: format)
        reader.add(out)
        reader.startReading()
        let per = Int(16_000 * hop)
        var levels: [Float] = []
        var acc: Double = 0, n = 0
        while let buf = out.copyNextSampleBuffer() {
            for x in samples(buf) {
                acc += Double(x * x); n += 1
                if n == per { levels.append(Float(10 * log10(acc / Double(n) + 1e-10))); acc = 0; n = 0 }
            }
        }
        return Analysis(duration: duration, hop: hop, levels: levels, words: nil)
    }

    /// Words with timings, using on-device speech recognition in chunks of about a minute,
    /// split at quiet moments so no word is cut in half.
    static func words(of url: URL, analysis a: Analysis, progress: @escaping (Double) -> Void) async -> [Word] {
        guard await authorized(),
              let rec = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              rec.supportsOnDeviceRecognition else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return [] }
        // One phrase at a time: the on-device recognizer drops requests that overlap.
        let list = chunks(a)
        var results = [[Word]](repeating: [], count: list.count)
        var next = 0, finished = 0
        await withTaskGroup(of: (Int, [Word]).self) { group in
            func launch() {
                guard next < list.count else { return }
                let i = next
                next += 1
                group.addTask { (i, await phrase(list[i], rec: rec, asset: asset, track: track)) }
            }
            launch()
            for await (i, ws) in group {
                results[i] = ws
                finished += 1
                progress(Double(finished) / Double(list.count))
                launch()
            }
        }
        let words = results.flatMap { $0 }
        log("captions: \(words.count) words in \(list.count) phrases")
        return words
    }

    private static func phrase(_ chunk: TimeSpan, rec: SFSpeechRecognizer, asset: AVURLAsset, track: AVAssetTrack) async -> [Word] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: chunk.start, preferredTimescale: 600),
                                       end: CMTime(seconds: chunk.end, preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: format)
        reader.add(out)
        reader.startReading()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        // One phrase per request: on-device recognition only times the words of its last utterance.
        let box = WordBox()
        let task = rec.recognitionTask(with: req) { result, error in
            if let r = result, r.isFinal {
                box.add(r.bestTranscription.segments.map {
                    Word(text: $0.substring, start: chunk.start + $0.timestamp, end: chunk.start + $0.timestamp + $0.duration)
                })
                box.markDone()
            }
            if error != nil { box.markDone() }
        }
        while let buf = out.copyNextSampleBuffer() {
            let xs = samples(buf)
            guard !xs.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(xs.count)) else { continue }
            b.frameLength = AVAudioFrameCount(xs.count)
            xs.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: xs.count) }
            req.append(b)
        }
        req.endAudio()
        let deadline = Date().addingTimeInterval(60)  // never hang on one phrase
        while !box.done, Date() < deadline { try? await Task.sleep(for: .milliseconds(40)) }
        if task.state != .completed { task.cancel() }
        return box.words
    }

    /// Spoken phrases: stretches of talking split at pauses, at most 20 seconds each.
    private static func chunks(_ a: Analysis) -> [TimeSpan] {
        let voiced = Cutter.voiced(a)
        guard !voiced.isEmpty else { return a.levels.isEmpty ? [] : [TimeSpan(start: 0, end: a.duration)] }
        var out: [TimeSpan] = []
        for v in voiced {
            if let last = out.last, v.start - last.end < 0.35, v.end - last.start < 20 { out[out.count - 1].end = v.end } else { out.append(v) }
        }
        return out.map { TimeSpan(start: max(0, $0.start - 0.15), end: min(a.duration, $0.end + 0.2)) }
    }

    private static func samples(_ buf: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(buf) else { return [] }
        let len = CMBlockBufferGetDataLength(block)
        var xs = [Float](repeating: 0, count: len / 4)
        xs.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
        return xs
    }

    private static func authorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
        default: return false
        }
    }

    // MARK: Cache (~/Library/Application Support/Bubble/Edits, never next to the videos)

    static func cacheURL(for url: URL, _ kind: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bubble/Edits", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Name + byte size identifies the recording without reading it.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let safe = url.deletingPathExtension().lastPathComponent.prefix(40).replacingOccurrences(of: "/", with: "-")
        return dir.appendingPathComponent("\(safe)-\(size)-\(kind).json")
    }

    static func load<T: Decodable>(_ t: T.Type, _ url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func save<T: Encodable>(_ v: T, _ url: URL) {
        if let d = try? JSONEncoder().encode(v) { try? d.write(to: url, options: .atomic) }
    }
}

private final class WordBox: @unchecked Sendable {
    private var list: [Word] = []
    private var finished = false
    private let lock = NSLock()
    func add(_ ws: [Word]) {
        lock.lock(); defer { lock.unlock() }
        let last = list.last?.end ?? -1
        list += ws.filter { $0.start >= last - 0.05 }
    }
    func markDone() {
        lock.lock(); defer { lock.unlock() }
        finished = true
    }
    var done: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var words: [Word] { lock.lock(); defer { lock.unlock() }; return list }
}

private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ f: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        f()
    }
}

// MARK: - Captions

struct CueWord: Equatable {
    var text: String
    var start: Double   // output seconds
    var end: Double
}

struct Cue: Equatable {
    var text: String
    var start: Double   // output seconds
    var end: Double
    var words: [CueWord]
    var range: Range<Int>   // which of the transcript's words
}

enum Captions {
    /// Short bursts of a few words, timed to the edit.
    static func cues(_ words: [Word], timeline: EditTimeline, perCue: Int) -> [Cue] {
        var cues: [Cue] = []
        var group: [(Int, CueWord)] = []
        let per = max(1, min(8, perCue))
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            cues.append(Cue(text: group.map { $0.1.text }.joined(separator: " "), start: first.1.start, end: last.1.end,
                            words: group.map(\.1), range: first.0..<(last.0 + 1)))
            group = []
        }
        for (i, w) in words.enumerated() {
            guard let s = timeline.output(at: w.start) else { flush(); continue }
            let e = timeline.output(at: w.end) ?? s + 0.25
            if let last = group.last, s - last.1.end > 0.6 { flush() }
            group.append((i, CueWord(text: w.text, start: s, end: max(e, s + 0.05))))
            if group.count >= per || w.text.last.map({ ".,!?".contains($0) }) == true { flush() }
        }
        flush()
        // Hold each caption until the next one starts (no flicker in short gaps).
        for i in cues.indices.dropLast() where cues[i + 1].start - cues[i].end < 0.5 { cues[i].end = cues[i + 1].start }
        return cues
    }

    static let presets: [(String, String)] = [("classic", "Classic"), ("karaoke", "Karaoke"), ("highlight", "Highlight"), ("box", "Box"), ("minimal", "Minimal")]

    /// A caption as a picture. `active` is the word being said, for the karaoke and highlight styles.
    static func image(_ cue: Cue, active: Int?, style: CaptionStyle, frame: CGSize) -> CIImage? {
        let short = min(frame.width, frame.height)
        let size = short * 0.068 * style.size * (style.preset == "minimal" ? 0.8 : 1)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let weight = style.preset == "minimal" ? "bold" : "heavy"
        let font = StudioType.font(style.font, size: size, weight: weight)
        let color = NSColor(hex: style.color), accent = NSColor(hex: style.accent)
        let words = cue.words.map { style.uppercase ? $0.text.uppercased() : $0.text }
        let text = words.joined(separator: " ")
        // Where each word sits in the text, to colour or mark the one being said.
        var ranges: [NSRange] = []
        var at = 0
        for w in words { ranges.append(NSRange(location: at, length: (w as NSString).length)); at += (w as NSString).length + 1 }

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(style.preset == "minimal" ? 0.7 : 0.55)
        shadow.shadowBlurRadius = size * 0.25
        shadow.shadowOffset = NSSize(width: 0, height: size * 0.06)
        let fill = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
        if style.preset != "box" { fill.addAttribute(.shadow, value: shadow, range: NSRange(location: 0, length: fill.length)) }
        if style.preset == "karaoke", let a = active, a < ranges.count { fill.addAttribute(.foregroundColor, value: accent, range: ranges[a]) }
        if style.preset == "highlight", let a = active, a < ranges.count {
            fill.addAttribute(.foregroundColor, value: accent.brightnessComponent > 0.6 ? NSColor.black : NSColor.white, range: ranges[a])
        }

        let maxW = min(frame.width * 0.86, short * 1.15)
        let block = StudioType.Block(fill, width: maxW)
        let pad = size * (style.preset == "box" ? 0.5 : 0.4)
        let w = Int(maxW + pad * 2), h = Int(ceil(block.used.height + pad * 2))
        let origin = CGPoint(x: pad, y: pad)
        return StudioType.picture(width: w, height: h) {
            if style.preset == "box" {
                let r = block.used.offsetBy(dx: pad, dy: pad).insetBy(dx: -size * 0.4, dy: -size * 0.22)
                NSColor.black.withAlphaComponent(0.72).setFill()
                NSBezierPath(roundedRect: r, xRadius: size * 0.25, yRadius: size * 0.25).fill()
            }
            if style.preset == "highlight", let a = active, a < ranges.count {
                let r = block.rect(of: ranges[a]).offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -size * 0.16, dy: -size * 0.04)
                accent.setFill()
                NSBezierPath(roundedRect: r, xRadius: size * 0.18, yRadius: size * 0.18).fill()
            }
            if style.preset == "classic" || style.preset == "karaoke" {
                let stroke = StudioType.Block(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.clear, .paragraphStyle: para,
                                                                                            .strokeColor: NSColor.black, .strokeWidth: 9]), width: maxW)
                stroke.draw(at: origin)
            }
            block.draw(at: origin)
        }
    }
}
