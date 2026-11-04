// The editor's sound studio. Works on each sound track of a recording on its own (Mercury records your
// microphone on the first track and the computer's sound, such as a call, on the second), once, in the
// background, and keeps the results with the edit (never next to the video):
//
//   Remove echo      your voice coming back through the call (a second device in the same call, or
//                    speakers into the mic) found by matching it against your microphone and turned down
//   Enhance speech   Apple's on-device voice isolation (the Voice Isolation mic mode), with a strength
//   Polish voice     low cut, a little less mud, more presence and air, gentle compression and a limiter
//   Loudness         measured the way broadcasters do (BS.1770), so the mix can be set to a target
//
// Everything runs on the Mac; nothing is uploaded.

import Accelerate
import AVFoundation

/// The processing a recording's sound needs. Changing any of it means processing again.
struct AudioRecipe: Codable, Hashable {
    var micEnhance = 0.0       // 0 off … 1 full voice isolation
    var sysEnhance = 0.0
    var echo = false
    var polish = false
    var target: Double?        // loudness to bring the mix to, in LUFS
    var isEmpty: Bool { micEnhance == 0 && sysEnhance == 0 && !echo && !polish && target == nil }
    var key: String { "\(Int(micEnhance * 20))-\(Int(sysEnhance * 20))-\(echo ? 1 : 0)\(polish ? 1 : 0)\(target.map { "-l\(Int(-$0))" } ?? "")" }
}

struct TrackStats: Codable {
    var power: Double          // gated, K-weighted mean square (BS.1770)
    var peak: Double
}

struct AudioResult: Codable {
    var files: [String: String] = [:]     // track index → processed file
    var stats: [String: TrackStats] = [:]
    var echoDelay: Double?                // seconds, when an echo was found
}

enum AudioStudio {
    static let rate = 48_000.0
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!

    static func resultURL(_ url: URL, _ r: AudioRecipe) -> URL { Analyzer.cacheURL(for: url, "audio-\(r.key)") }

    /// A finished result for this recipe, if every file it names is still there.
    static func load(_ url: URL, _ r: AudioRecipe) -> AudioResult? {
        guard let res = Analyzer.load(AudioResult.self, resultURL(url, r)),
              res.files.values.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else { return nil }
        return res
    }

    static func process(_ url: URL, _ r: AudioRecipe, progress: @escaping @Sendable (Double) -> Void) async throws -> AudioResult {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw NSError(domain: "Bubble", code: 4, userInfo: [NSLocalizedDescriptionKey: "This recording has no sound."]) }
        let duration = try await asset.load(.duration).seconds
        let dir = resultURL(url, r).deletingLastPathComponent().appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tag = UUID().uuidString.prefix(6)
        var temps: [URL] = []
        defer { for t in temps { try? FileManager.default.removeItem(at: t) } }
        func temp(_ name: String) -> URL { let u = dir.appendingPathComponent(".\(tag)-\(name).caf"); temps.append(u); return u }

        // 1. Each track as plain samples.
        var decoded: [URL] = []
        for (i, t) in tracks.enumerated() {
            let u = temp("t\(i)")
            try await decode(asset, t, to: u) { p in progress((Double(i) + p) / Double(tracks.count) * 0.2) }
            decoded.append(u)
        }
        var res = AudioResult()
        var work = decoded

        // 2. Your voice coming back through the computer's sound.
        if r.echo, decoded.count >= 2 {
            if let delay = try estimateDelay(mic: decoded[0], other: decoded[1]) {
                res.echoDelay = Double(delay.global) / rate
                let u = temp("echo")
                try suppressEcho(in: decoded[1], reference: decoded[0], delays: delay, to: u) { p in progress(0.2 + p * 0.3) }
                work[1] = u
                log("audio: echo of \(String(format: "%.0f", Double(delay.global) / rate * 1000)) ms removed from the computer sound")
            } else {
                log("audio: no echo found")
            }
        }

        // 3. Enhance and polish, then keep each changed track.
        for i in work.indices {
            let enhance = i == 0 ? r.micEnhance : r.sysEnhance
            var final = work[i]
            if enhance > 0 || r.polish {
                let u = temp("fx\(i)")
                try render(work[i], to: u, enhance: enhance, polish: r.polish) { p in progress(0.5 + (Double(i) + p) / Double(work.count) * 0.35) }
                final = u
            }
            // Up to the loudness target, a limiter catching the few peaks a plain boost would clip.
            // Two voices add up, so with a second track each aims 3 dB lower.
            if let target = r.target {
                let now = try loudness(final)
                let lufs = -0.691 + 10 * log10(max(now.power, 1e-12))
                if now.power > 0, lufs > -60 {
                    let aim = target - (work.count > 1 ? 3 : 0)
                    var gain = min(18, max(-12, aim - lufs))
                    if abs(gain) > 0.3 {
                        // Pushed 3 dB harder into the limiter, then 3 dB down: on target, with room for speed changes to overshoot.
                        // The limiter takes a little loudness with it, so one more go makes up the difference.
                        let source = final
                        var u = temp("lvl\(i)")
                        try render(source, to: u, enhance: 0, polish: false, limiterGain: gain + 3, outGain: 0.708) { _ in }
                        let got = -0.691 + 10 * log10(max(try loudness(u).power, 1e-12))
                        if aim - got > 0.4 {
                            gain = min(20, gain + (aim - got))
                            u = temp("lvl\(i)b")
                            try render(source, to: u, enhance: 0, polish: false, limiterGain: gain + 3, outGain: 0.708) { _ in }
                        }
                        final = u
                    }
                }
            }
            if final != decoded[i] {
                let out = dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent.prefix(30))-\(r.key)-t\(i).m4a")
                try encode(final, to: out)
                res.files["\(i)"] = out.path
            }
            res.stats["\(i)"] = try loudness(final)
            progress(0.85 + Double(i + 1) / Double(work.count) * 0.15)
        }
        Analyzer.save(res, resultURL(url, r))
        log("audio: \(res.files.count) track(s) processed for \(Int(duration)) s, recipe \(r.key)")
        return res
    }

    // MARK: Files

    private static func decode(_ asset: AVURLAsset, _ track: AVAssetTrack, to u: URL, progress: (Double) -> Void) async throws {
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(out)
        reader.startReading()
        let file = try AVAudioFile(forWriting: u, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        // A track that starts late is padded so every track lines up with the video.
        let start = (try? await track.load(.timeRange).start.seconds) ?? 0
        if start > 0.001 { try write([Float](repeating: 0, count: Int(start * rate)), to: file) }
        var done = 0.0
        while let buf = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buf) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            var xs = [Float](repeating: 0, count: len / 4)
            xs.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            try write(xs, to: file)
            done += Double(xs.count) / rate
            progress(min(1, done / max(1, duration)))
        }
    }

    private static func write(_ xs: [Float], to file: AVAudioFile) throws {
        guard !xs.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(xs.count)) else { return }
        b.frameLength = AVAudioFrameCount(xs.count)
        xs.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: xs.count) }
        try file.write(from: b)
    }

    /// Reads a stretch of samples (zeros past either end).
    private static func read(_ file: AVAudioFile, at pos: Int64, count: Int) throws -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let start = max(0, pos), skip = Int(start - pos)
        guard start < file.length, count - skip > 0 else { return out }
        let n = AVAudioFrameCount(min(Int64(count - skip), file.length - start))
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return out }
        file.framePosition = start
        try file.read(into: b, frameCount: n)
        let got = Int(b.frameLength)
        if got > 0 { out.withUnsafeMutableBufferPointer { _ = memcpy($0.baseAddress! + skip, b.floatChannelData![0], got * 4) } }
        return out
    }

    private static func encode(_ src: URL, to dest: URL) throws {
        let input = try AVAudioFile(forReading: src)
        try? FileManager.default.removeItem(at: dest)
        let output = try AVAudioFile(forWriting: dest, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                                                  AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 192_000],
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16)!
        while input.framePosition < input.length {
            try input.read(into: b, frameCount: 1 << 16)
            if b.frameLength == 0 { break }
            try output.write(from: b)
        }
    }

    // MARK: Finding the echo

    struct Delays {
        var global: Int                 // samples
        var perBlock: [Int]             // samples, one per 20 s
        func at(_ sample: Int) -> Int { perBlock.isEmpty ? global : perBlock[min(perBlock.count - 1, max(0, sample / (20 * 48_000)))] }
    }

    /// Loudness every 10 ms, as log values.
    private static func envelope(_ u: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: u)
        var env: [Float] = []
        var pos: Int64 = 0
        let hop = 480
        while pos < f.length {
            let xs = try read(f, at: pos, count: hop * 2000)
            var i = 0
            while i + hop <= xs.count, pos + Int64(i) < f.length {
                var ms: Float = 0
                xs.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + i, 1, &ms, vDSP_Length(hop)) }
                env.append(log(sqrt(ms) + 1e-5))
                i += hop
            }
            pos += Int64(hop * 2000)
        }
        return env
    }

    /// How long after your microphone your voice turns up again in the other track, if it does.
    private static func estimateDelay(mic: URL, other: URL) throws -> Delays? {
        var a = try envelope(mic), b = try envelope(other)
        let n = min(a.count, b.count)
        guard n > 1000 else { return nil }
        a = Array(a[0..<n]); b = Array(b[0..<n])
        let ma = a.reduce(0, +) / Float(n), mb = b.reduce(0, +) / Float(n)
        a = a.map { $0 - ma }; b = b.map { $0 - mb }
        func corr(_ lag: Int, _ lo: Int, _ hi: Int) -> Float {
            var s: Float = 0, na: Float = 0, nb: Float = 0
            var i = lo
            while i < hi - lag { s += a[i] * b[i + lag]; na += a[i] * a[i]; nb += b[i + lag] * b[i + lag]; i += 1 }
            return s / (sqrt(na * nb) + 1e-6)
        }
        // Echoes from a call come back between a few milliseconds and about two seconds later.
        var best = (lag: 0, c: Float(-1))
        for lag in 1...200 { let c = corr(lag, 0, n); if c > best.c { best = (lag, c) } }
        // A real echo stands out clearly against no delay at all.
        guard best.c > 0.12, best.c > corr(0, 0, n) + 0.04 else { return nil }
        // Calls drift a little: look again every 20 seconds, near the overall delay.
        var blocks: [Int] = []
        var lo = 0
        while lo < n {
            let hi = min(n, lo + 2000)
            var bb = (lag: best.lag, c: Float(-1))
            if hi - lo > 300 { for lag in max(1, best.lag - 15)...(best.lag + 15) { let c = corr(lag, lo, hi); if c > bb.c { bb = (lag, c) } } }
            blocks.append(bb.c > 0.08 ? bb.lag : (blocks.last ?? best.lag))
            lo = hi
        }
        // Smooth out the odd wrong guess.
        let smooth = blocks.indices.map { i -> Int in
            let w = blocks[max(0, i - 2)...min(blocks.count - 1, i + 2)].sorted()
            return w[w.count / 2]
        }
        return Delays(global: best.lag * 480, perBlock: smooth.map { $0 * 480 })
    }

    // MARK: Removing it

    private final class FFT {
        let n = 1024
        let fwd = vDSP.DFT(count: 1024, direction: .forward, transformType: .complexReal, ofType: Float.self)!
        let inv = vDSP.DFT(count: 1024, direction: .inverse, transformType: .complexReal, ofType: Float.self)!
        let window: [Float] = (0..<1024).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / 1024) }
        /// Spectrum in the packed layout: re[0] = DC, im[0] = Nyquist.
        func forward(_ x: [Float]) -> ([Float], [Float]) {
            let w = vDSP.multiply(x, window)
            var re = [Float](repeating: 0, count: 512), im = re
            for i in 0..<512 { re[i] = w[2 * i]; im[i] = w[2 * i + 1] }
            var fr = re, fi = im
            fwd.transform(inputReal: re, inputImaginary: im, outputReal: &fr, outputImaginary: &fi)
            return (fr, fi)
        }
        func power(_ s: ([Float], [Float])) -> [Float] {
            var p = [Float](repeating: 0, count: 513)
            p[0] = s.0[0] * s.0[0]; p[512] = s.1[0] * s.1[0]
            for k in 1..<512 { p[k] = s.0[k] * s.0[k] + s.1[k] * s.1[k] }
            return p
        }
        func inverse(_ fr: [Float], _ fi: [Float]) -> [Float] {
            var tr = [Float](repeating: 0, count: 512), ti = tr
            inv.transform(inputReal: fr, inputImaginary: fi, outputReal: &tr, outputImaginary: &ti)
            var out = [Float](repeating: 0, count: 1024)
            let scale = 1 / Float(2 * n)
            for i in 0..<512 { out[2 * i] = tr[i] * scale; out[2 * i + 1] = ti[i] * scale }
            return out
        }
    }

    /// Turns down the parts of the other track that match your microphone from a moment before:
    /// how strongly your voice comes back in each frequency band is learnt first, then each moment is
    /// reduced by how much of it is that returning voice. Other voices, which your mic doesn't have,
    /// pass through.
    private static func suppressEcho(in otherURL: URL, reference refURL: URL, delays: Delays, to outURL: URL, progress: (Double) -> Void) throws {
        let fft = FFT(), n = 1024, hop = 512
        let other = try AVAudioFile(forReading: otherURL), ref = try AVAudioFile(forReading: refURL)
        let total = Int(other.length)
        func refFrame(_ pos: Int) throws -> [Float] { try read(ref, at: Int64(pos - delays.at(pos)), count: n) }

        // How strongly the voice comes back, per band: the typical ratio over moments you're talking.
        let learnFrames = min(total / hop - 2, Int(180 * rate) / hop)
        var refEnergy: [Float] = []
        var samples: [[Float]] = Array(repeating: [], count: 513)
        if learnFrames > 50 {
            var energies: [(Float, Int)] = []
            for f in stride(from: 0, to: learnFrames, by: 2) {
                let x = try refFrame(f * hop)
                var ms: Float = 0
                vDSP_measqv(x, 1, &ms, vDSP_Length(n))
                energies.append((ms, f))
            }
            refEnergy = energies.map(\.0).sorted()
            let loud = refEnergy[Int(Double(refEnergy.count) * 0.7)]
            for (e, f) in energies where e >= loud {
                let pr = fft.power(fft.forward(try refFrame(f * hop)))
                let py = fft.power(fft.forward(try read(other, at: Int64(f * hop), count: n)))
                for k in 0...512 where pr[k] > 1e-9 { samples[k].append(py[k] / pr[k]) }
            }
        }
        var coupling = samples.map { s -> Float in
            guard !s.isEmpty else { return 0 }
            let sorted = s.sorted()
            return sorted[sorted.count / 2]
        }
        // Smooth across neighbouring bands.
        coupling = coupling.indices.map { k in
            let w = coupling[max(0, k - 2)...min(512, k + 2)]
            return w.reduce(0, +) / Float(w.count)
        }

        let out = try AVAudioFile(forWriting: outURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var overlap = [Float](repeating: 0, count: n)
        var lastGain = [Float](repeating: 1, count: 513)
        var recent: [[Float]] = []      // your voice's power over the last few frames (drift tolerance)
        var pos = 0
        var pending: [Float] = []
        let beta: Float = 2.2, floorGain: Float = 0.04
        while pos < total + n {
            let y = try read(other, at: Int64(pos), count: n)
            let spec = fft.forward(y)
            let py = fft.power(spec)
            // A frame of your voice a little ahead too, so a delay that wanders by ±10 ms is still caught.
            recent.append(fft.power(fft.forward(try refFrame(pos + hop))))
            if recent.count > 3 { recent.removeFirst() }
            var fr = spec.0, fi = spec.1
            var gain = [Float](repeating: 1, count: 513)
            for k in 0...512 {
                var pr: Float = 0
                for r in recent { pr = max(pr, r[k]) }
                let echo = beta * coupling[k] * pr
                var g = py[k] > 1e-12 ? 1 - echo / py[k] : 1
                g = min(1, max(floorGain, g))
                // Turn down quickly, come back up gently.
                g = g < lastGain[k] ? g : 0.6 * lastGain[k] + 0.4 * g
                gain[k] = g
            }
            for k in 0...512 { lastGain[k] = gain[k] }
            fr[0] *= gain[0]; fi[0] *= gain[512]
            for k in 1..<512 { let g = (gain[k - 1] + 2 * gain[k] + gain[k + 1]) / 4; fr[k] *= g; fi[k] *= g }
            let frame = fft.inverse(fr, fi)
            for i in 0..<n { overlap[i] += frame[i] }
            pending += overlap[0..<hop]
            overlap = Array(overlap[hop...]) + [Float](repeating: 0, count: hop)
            if pending.count >= 1 << 15 { try write(pending, to: out); pending = [] }
            pos += hop
            if pos % (hop * 2000) == 0 { try Task.checkCancellation(); progress(min(1, Double(pos) / Double(total))) }
        }
        try write(Array(pending.prefix(max(0, total - Int(out.length)))), to: out)
        progress(1)
    }

    // MARK: Enhance and polish

    private static func render(_ inURL: URL, to outURL: URL, enhance: Double, polish: Bool, limiterGain: Double? = nil, outGain: Float = 1,
                               progress: (Double) -> Void) throws {
        let input = try AVAudioFile(forReading: inURL)
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        engine.attach(player)
        var chain: [AVAudioNode] = []
        func apple(_ sub: String) -> AVAudioUnitEffect {
            let code = sub.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: code,
                                                                                         componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        }
        if enhance > 0 {
            let iso = apple("vois")
            AudioUnitSetParameter(iso.audioUnit, 0, kAudioUnitScope_Global, 0, Float(min(1, enhance) * 100), 0)   // wet/dry
            AudioUnitSetParameter(iso.audioUnit, 1, kAudioUnitScope_Global, 0, 1, 0)                             // voice
            chain.append(iso)
        }
        if polish {
            let eq = AVAudioUnitEQ(numberOfBands: 4)
            let b = eq.bands
            b[0].filterType = .highPass; b[0].frequency = 85; b[0].bypass = false
            b[1].filterType = .parametric; b[1].frequency = 280; b[1].bandwidth = 1.2; b[1].gain = -2.5; b[1].bypass = false
            b[2].filterType = .parametric; b[2].frequency = 3800; b[2].bandwidth = 1.4; b[2].gain = 3; b[2].bypass = false
            b[3].filterType = .highShelf; b[3].frequency = 10_000; b[3].gain = 2; b[3].bypass = false
            chain.append(eq)
            let comp = apple("dcmp")
            for (p, v) in [(0, -26.0), (1, 6.0), (2, 2.0), (3, -62.0), (4, 0.004), (5, 0.12), (6, 5.0)] as [(UInt32, Double)] {
                AudioUnitSetParameter(comp.audioUnit, p, kAudioUnitScope_Global, 0, Float(v), 0)
            }
            chain.append(comp)
            chain.append(apple("lmtr"))
        }
        if let g = limiterGain {
            let lim = apple("lmtr")
            AudioUnitSetParameter(lim.audioUnit, 0, kAudioUnitScope_Global, 0, 0.004, 0)    // attack
            AudioUnitSetParameter(lim.audioUnit, 1, kAudioUnitScope_Global, 0, 0.06, 0)     // release
            AudioUnitSetParameter(lim.audioUnit, 2, kAudioUnitScope_Global, 0, Float(g), 0) // pre-gain, dB
            chain.append(lim)
        }
        for c in chain { engine.attach(c) }
        var last: AVAudioNode = player
        for c in chain { engine.connect(last, to: c, format: format); last = c }
        engine.connect(last, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        player.scheduleFile(input, at: nil)
        player.play()
        // The effects hold the sound back a little; trim that so it stays in sync with the video.
        let latency = chain.compactMap { ($0 as? AVAudioUnit)?.auAudioUnit.latency }.reduce(0, +)
        var skip = Int(latency * rate)
        let total = Int(input.length)
        let out = try AVAudioFile(forWriting: outURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var written = 0
        while written < total {
            let st = try engine.renderOffline(4096, to: buf)
            guard st == .success || st == .insufficientDataFromInputNode else { break }
            var xs = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
            if skip > 0 { let k = min(skip, xs.count); xs.removeFirst(k); skip -= k }
            xs = Array(xs.prefix(total - written))
            if outGain != 1 { vDSP.multiply(outGain, xs, result: &xs) }
            try write(xs, to: out)
            written += xs.count
            if written % (4096 * 200) < 4096 { try Task.checkCancellation(); progress(Double(written) / Double(max(1, total))) }
        }
        engine.stop()
    }

    // MARK: Loudness (ITU-R BS.1770 / EBU R128)

    static func loudness(_ u: URL) throws -> TrackStats {
        let f = try AVAudioFile(forReading: u)
        // K-weighting at 48 kHz: a high shelf, then a high pass.
        var s1 = (0.0, 0.0), s2 = (0.0, 0.0)
        let b1 = (1.53512485958697, -2.69169618940638, 1.19839281085285), a1 = (-1.69065929318241, 0.73248077421585)
        let b2 = (1.0, -2.0, 1.0), a2 = (-1.99004745483398, 0.99007225036621)
        var blocks: [Double] = []       // mean square per 100 ms
        var acc = 0.0, count = 0, peak = 0.0
        var pos: Int64 = 0
        while pos < f.length {
            let xs = try read(f, at: pos, count: Int(min(Int64(1 << 16), f.length - pos)))
            for x in xs {
                let v = Double(x)
                peak = max(peak, abs(v))
                let y1 = b1.0 * v + s1.0; s1.0 = b1.1 * v - a1.0 * y1 + s1.1; s1.1 = b1.2 * v - a1.1 * y1
                let y2 = b2.0 * y1 + s2.0; s2.0 = b2.1 * y1 - a2.0 * y2 + s2.1; s2.1 = b2.2 * y1 - a2.1 * y2
                acc += y2 * y2; count += 1
                if count == 4800 { blocks.append(acc / 4800); acc = 0; count = 0 }
            }
            pos += Int64(xs.count)
        }
        // 400 ms windows every 100 ms, then the absolute and relative gates.
        var windows: [Double] = []
        if blocks.count >= 4 { for i in 0...(blocks.count - 4) { windows.append((blocks[i] + blocks[i + 1] + blocks[i + 2] + blocks[i + 3]) / 4) } }
        func lufs(_ ms: Double) -> Double { -0.691 + 10 * log10(max(ms, 1e-12)) }
        let abs = windows.filter { lufs($0) > -70 }
        guard !abs.isEmpty else { return TrackStats(power: 0, peak: peak) }
        let rel = lufs(abs.reduce(0, +) / Double(abs.count)) - 10
        let gated = abs.filter { lufs($0) > rel }
        return TrackStats(power: gated.isEmpty ? 0 : gated.reduce(0, +) / Double(gated.count), peak: peak)
    }

    /// The gain that brings the mix to a loudness target, without letting it clip.
    static func gain(to target: Double, _ res: AudioResult, volumes: [Double]) -> Double {
        var power = 0.0, peak = 0.0
        for (k, s) in res.stats {
            let v = volumes[min(volumes.count - 1, Int(k) ?? 0)]
            power += v * v * s.power
            peak = max(peak, s.peak * v)
        }
        guard power > 0 else { return 1 }
        let now = -0.691 + 10 * log10(power)
        var g = pow(10, (target - now) / 20)
        // Never louder than the processing left the peaks (about −3 dBFS), so nothing clips after encoding.
        if peak > 0 { g = min(g, 0.72 / peak) }
        return min(8, max(0.1, g))
    }

    /// A gain for each spoken phrase that brings quiet and loud ones to about the same level.
    static func phraseGains(levels: [Float], hop: Double, voiced: [TimeSpan]) -> [(TimeSpan, Double)] {
        let target = -22.0
        return voiced.map { v in
            let a = max(0, Int(v.start / hop)), b = min(levels.count, Int(v.end / hop))
            guard b > a else { return (v, 1.0) }
            let p = levels[a..<b].reduce(0.0) { $0 + pow(10, Double($1) / 10) } / Double(b - a)
            let db = 10 * log10(max(p, 1e-10))
            return (v, min(3, max(0.5, pow(10, (target - db) / 20))))
        }
    }
}
