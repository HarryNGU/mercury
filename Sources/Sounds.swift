// Mercury's own sound effects, synthesised at launch (no audio files): a rising "bloop" when
// recording starts, a falling one when it ends, a soft tick for each countdown number, and the
// gentle pops and chimes of the welcome tour.

import AVFoundation

enum Sounds {
    private static var players: [String: AVAudioPlayer] = [:]
    private static let rate = 48_000.0

    static func preload() {
        players["start"] = player(bloop(from: 520, to: 980, second: 1320))
        players["stop"] = player(bloop(from: 980, to: 560, second: 440))
        players["tick"] = player(tick())
        loadVoiceSounds()
        players["start"]?.volume = 0.55
        players["stop"]?.volume = 0.55
        players["tick"]?.volume = 0.35
        loadTourSounds()
        log("sounds ready: \(players.values.count)")
    }

    static func start() { play("start") }
    static func stop() { play("stop") }
    static func tick() { play("tick") }
    /// Dictation starts listening / stops listening.
    static func listen() { play("listen") }
    static func heard() { play("heard") }

    /// The welcome tour, which plays out like a chat. Across the tour the sounds make a low, wandering
    /// melody that rises and falls, and each step ends with its own sound, so it never just climbs.
    enum Tour: String, CaseIterable {
        case hello, m0, m1, m2, m3, step0, step1, step2, step3, step4, step5, on, off, granted, granted2, ready, finish, incoming, impact, rumble, reveal
        fileprivate var volume: Float {
            switch self {
            case .hello: 0.5
            case .m0, .m1, .m2, .m3: 0.7
            case .step0, .step2, .step4: 0.6        // wood and mallet
            case .step1, .step3, .step5: 0.75       // pops are softer, so a little more
            case .on, .off: 0.6
            case .granted, .granted2: 0.5
            case .ready: 0.55
            case .finish: 0.6
            case .incoming: 0.7
            case .impact: 1.0
            case .rumble: 0.75
            case .reveal: 0.85
            }
        }
    }

    static func tour(_ t: Tour) { play("tour." + t.rawValue) }

    /// Mercury's message number `n`: rises, falls, does both, then sinks low, starting somewhere different each step.
    static func tourMessage(_ n: Int) { tour([Tour.m0, .m1, .m2, .m3][n % 4]) }
    /// The sound for finishing tour step `n`.
    static func tourStep(_ n: Int) { tour([Tour.step0, .step1, .step2, .step3, .step4, .step5][max(0, n) % 6]) }

    private static let c4 = 261.6, d4 = 293.7, e4 = 329.6, f4 = 349.2, g4 = 392.0, a4 = 440.0, c5 = 523.3

    private static func samples(_ t: Tour) -> [Float] {
        switch t {
        case .hello: return mallets([e4, g4, c5, g4], gap: 0.13, length: 1.3, decay: 0.32)               // up, then settles
        case .m0: return pops([(290, 390)])
        case .m1: return pops([(380, 280)])
        case .m2: return pops([(300, 390), (390, 300)])
        case .m3: return pops([(300, 225)])
        case .step0: return chime([c4, e4])                                                              // wood, up
        case .step1: return pops([(370, 300), (300, 240)])                                               // pops, down
        case .step2: return mallets([d4, g4, e4], gap: 0.1, length: 0.8, decay: 0.16)                     // up and back
        case .step3: return chime([f4, d4])                                                              // wood, down
        case .step4: return pops([(250, 340), (340, 430), (390, 300)])                                   // climbs, then drops
        case .step5: return mallets([g4, e4, a4, g4], gap: 0.09, length: 0.9, decay: 0.16)                // down, up, down
        case .on: return pops([(260, 360)])
        case .off: return pops([(350, 250)])
        case .granted: return mallets([g4, c5], gap: 0.09, length: 0.7, decay: 0.18)
        case .granted2: return mallets([a4, f4], gap: 0.09, length: 0.7, decay: 0.18)
        case .ready: return mallets([c4, g4, e4, a4, g4, c5], gap: 0.14, length: 2.2, decay: 0.5)         // wanders up and down, lands home
        case .finish: return chime([g4, c4])
        case .incoming: return whoosh(0.6, from: 400, to: 5000, peakAt: 0.92)
        case .impact: return explosion()
        case .rumble: return rumble(2.4)
        case .reveal: return reveal()
        }
    }

    private static func loadTourSounds() {
        for t in Tour.allCases {
            let key = "tour." + t.rawValue
            players[key] = player(samples(t))
            players[key]?.volume = t.volume
        }
    }

    /// For the offscreen check: length and loudness of each tour sound. Plays nothing.
    static func tourLevels() -> [String] {
        Tour.allCases.map { t in
            let x = samples(t)
            let peak = x.map { abs($0) }.max() ?? 0
            let rms = (x.map { $0 * $0 }.reduce(0, +) / Float(max(1, x.count))).squareRoot()
            return String(format: "%@ %.2fs peak %.2f rms %.3f", t.rawValue, Double(x.count) / rate, peak, rms)
        }
    }

    /// The voice sounds you can pick in Dictation settings.
    enum VoiceStyle: String, CaseIterable, Identifiable {
        case pop, wood, glass
        var id: String { rawValue }
        var title: String { switch self { case .pop: "Soft pop"; case .wood: "Wood"; case .glass: "Glass" } }
    }

    static var voiceStyle: VoiceStyle {
        get { VoiceStyle(rawValue: Settings.d.string(forKey: "voiceSound") ?? "") ?? .pop }
        set { Settings.d.set(newValue.rawValue, forKey: "voiceSound"); loadVoiceSounds() }
    }

    static func loadVoiceSounds() {
        switch voiceStyle {
        case .pop:
            players["listen"] = player(pops([(250, 360), (300, 430)]))   // two low, rounded pops, rising
            players["heard"] = player(pops([(380, 260)]))                // one pop, falling
        case .wood:
            players["listen"] = player(chime([392.0, 523.3]))  // G4 then C5
            players["heard"] = player(chime([523.3, 392.0]))
        case .glass:
            players["listen"] = player(chime([659.3, 987.8]))  // the original: E5 then B5
            players["heard"] = player(chime([987.8, 784.0]))
        }
        players["listen"]?.volume = voiceStyle == .pop ? 0.85 : 0.45
        players["heard"]?.volume = voiceStyle == .pop ? 0.75 : 0.38
    }

    private static func play(_ name: String) {
        guard Settings.sounds, let p = players[name] else { return }
        p.currentTime = 0
        p.play()
    }

    // MARK: Synthesis

    /// Two quick sine "drops": a pitch glide with a soft attack, then a higher (or lower) chime.
    private static func bloop(from f0: Double, to f1: Double, second f2: Double) -> [Float] {
        let n = Int(rate * 0.42)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<Int(rate * 0.16) {
            let t = Double(i) / rate
            let f = f0 + (f1 - f0) * min(1, t / 0.07)
            phase += 2 * .pi * f / rate
            let env = min(1, t / 0.006) * exp(-t / 0.05)
            out[i] += Float(sin(phase) * env * 0.8)
        }
        let offset = Int(rate * 0.075)
        var p2 = 0.0
        for i in 0..<(n - offset) {
            let t = Double(i) / rate
            p2 += 2 * .pi * f2 / rate
            let env = min(1, t / 0.004) * exp(-t / 0.09)
            out[offset + i] += Float((sin(p2) + 0.25 * sin(2 * p2)) * env * 0.45)
        }
        return out
    }

    /// Muted "bloop" pops: a sine whose pitch slides like a bubble, with a soft start, a quick
    /// fade and the top end rolled off, so it reads as a gentle tap rather than a beep.
    private static func pops(_ glides: [(Double, Double)]) -> [Float] {
        let n = Int(rate * 0.32)
        var out = [Double](repeating: 0, count: n)
        for (k, g) in glides.enumerated() {
            let offset = Int(rate * 0.075) * k
            var phase = 0.0
            for i in 0..<(n - offset) {
                let t = Double(i) / rate
                let f = g.0 + (g.1 - g.0) * (1 - exp(-t / 0.025))
                phase += 2 * .pi * f / rate
                let env = min(1, t / 0.008) * exp(-t / 0.055)
                out[offset + i] += (sin(phase) + 0.12 * sin(2 * phase)) * env * 0.45
            }
        }
        var y = 0.0, y2 = 0.0
        return out.map { x in y += 0.22 * (x - y); y2 += 0.22 * (y - y2); return Float(y2) }
    }

    /// Two soft mallet notes, like a marimba in a small room: a rounded attack, a tiny pitch
    /// settle, a fast-fading bright overtone, gentle low-pass and a short room echo.
    private static func chime(_ notes: [Double]) -> [Float] {
        let n = Int(rate * 0.55)
        var dry = [Double](repeating: 0, count: n)
        for (k, f) in notes.enumerated() {
            let offset = Int(rate * 0.085) * k
            let gain = k == 0 ? 0.8 : 1.0
            var p1 = 0.0, p4 = 0.0
            for i in 0..<(n - offset) {
                let t = Double(i) / rate
                let bend = 1 + 0.012 * exp(-t / 0.012)  // lands on pitch, like a struck bar
                p1 += 2 * .pi * f * bend / rate
                p4 += 2 * .pi * f * 3.9 / rate
                let body = sin(p1) * exp(-t / 0.16)
                let bright = sin(p4) * 0.18 * exp(-t / 0.018)
                let attack = min(1, t / 0.005)
                dry[offset + i] += (body + bright) * attack * gain * 0.42
            }
        }
        // Room: a few soft early reflections.
        var wet = dry
        for (ms, g) in [(23.0, 0.22), (41.0, 0.16), (67.0, 0.11), (97.0, 0.07)] {
            let d = Int(rate * ms / 1000)
            for i in d..<n { wet[i] += dry[i - d] * g }
        }
        // One-pole low-pass takes the edge off.
        var y = 0.0
        return wet.map { x in y += 0.35 * (x - y); return Float(y) }
    }

    /// A rising run of soft mallet notes that ring into each other, for the tour's bigger moments.
    private static func mallets(_ notes: [Double], gap: Double, length: Double, decay: Double) -> [Float] {
        let n = Int(rate * length)
        var dry = [Double](repeating: 0, count: n)
        for (k, f) in notes.enumerated() {
            let offset = Int(rate * gap) * k
            var p1 = 0.0, p2 = 0.0, p4 = 0.0
            for i in 0..<(n - offset) {
                let t = Double(i) / rate
                p1 += 2 * .pi * f * (1 + 0.01 * exp(-t / 0.012)) / rate
                p2 += 2 * .pi * f * 2 / rate
                p4 += 2 * .pi * f * 3.9 / rate
                let tone = sin(p1) * exp(-t / decay) + sin(p2) * 0.14 * exp(-t / (decay * 0.4)) + sin(p4) * 0.12 * exp(-t / 0.018)
                dry[offset + i] += tone * min(1, t / 0.005)
            }
        }
        var wet = dry
        for (ms, g) in [(23.0, 0.22), (41.0, 0.16), (67.0, 0.11), (97.0, 0.07), (140.0, 0.05)] {
            let d = Int(rate * ms / 1000)
            for i in d..<n { wet[i] += dry[i - d] * g }
        }
        var y = 0.0
        var out = wet.map { x -> Double in y += 0.35 * (x - y); return y }
        // Level it, then fade the very end so it can never click.
        let peak = out.map(abs).max() ?? 1
        let tail = Int(rate * 0.12)
        for i in out.indices { out[i] *= 0.8 / peak * min(1, Double(n - i) / Double(tail)) }
        return out.map(Float.init)
    }

    // MARK: The arrival: a shooting star landing

    private static func noise(_ n: Int, seed: UInt64) -> [Double] {
        var x = seed &* 6364136223846793005 &+ 1442695040888963407
        return (0..<n).map { _ in x = x &* 6364136223846793005 &+ 1442695040888963407; return Double(Int64(bitPattern: x >> 1) % 2_000_001) / 1_000_000 - 1 }
    }

    /// Hard limiting that keeps a big sound loud without crackling on laptop speakers.
    private static func limit(_ x: [Double], drive: Double = 1.8, peak: Double = 0.95) -> [Float] {
        var y = x.map { tanh($0 * drive) / tanh(drive) }
        let m = y.map(abs).max() ?? 1
        if m > 0 { y = y.map { $0 * peak / m } }
        let tail = min(y.count, Int(rate * 0.08))
        for i in 0..<tail { y[y.count - 1 - i] *= Double(i) / Double(tail) }
        return y.map(Float.init)
    }

    /// Air rushing in: noise through a filter that opens up, rising to a peak.
    private static func whoosh(_ length: Double, from f0: Double, to f1: Double, peakAt: Double) -> [Float] {
        let n = Int(rate * length), w = noise(n, seed: 7)
        var y = [Double](repeating: 0, count: n), lp = 0.0
        for i in 0..<n {
            let t = Double(i) / Double(n)
            let fc = f0 * pow(f1 / f0, t)
            let a = 1 - exp(-2 * .pi * fc / rate)
            lp += a * (w[i] - lp)
            let env = t < peakAt ? pow(t / peakAt, 2.2) : max(0, 1 - (t - peakAt) / (1 - peakAt))
            y[i] = lp * env
        }
        return limit(y, drive: 1.2, peak: 0.8)
    }

    /// The impact: a sharp crack, a gritty body of noise and a bass thump laptop speakers can carry
    /// (80 to 160 Hz, with its overtone), then a short echo, all behind a limiter.
    private static func explosion() -> [Float] {
        let n = Int(rate * 2.4), w = noise(n, seed: 42), grit = noise(n, seed: 99)
        var y = [Double](repeating: 0, count: n)
        var brown = 0.0, hp = 0.0, prev = 0.0, lp = 0.0
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / rate
            // Crack: a very short burst of bright noise.
            let crack = (w[i] - prev) * exp(-t / 0.012) * 1.6
            prev = w[i]
            // Body: rumbling noise that dies away, with crackle scattered through it.
            brown = brown * 0.985 + w[i] * 0.15
            hp = 0.995 * (hp + brown - (i > 0 ? y[i - 1] * 0 : 0)) // gentle DC block
            lp += 0.08 * (brown - lp)
            let crackle = abs(grit[i]) > 0.985 ? grit[i] * 2.2 * exp(-t / 0.7) : 0
            let body = (lp * 2.4 + crackle) * exp(-t / 0.55) * min(1, t / 0.004)
            // Thump: a pitch drop from 160 to 70 Hz, plus its overtone so small speakers still punch.
            let f = 70 + 90 * exp(-t / 0.09)
            phase += 2 * .pi * f / rate
            let thump = (sin(phase) + 0.45 * sin(2 * phase)) * exp(-t / 0.42) * min(1, t / 0.003)
            y[i] = crack + body * 0.9 + thump * 1.1
        }
        var wet = y
        for (ms, g) in [(63.0, 0.35), (118.0, 0.25), (187.0, 0.16), (271.0, 0.1)] {
            let d = Int(rate * ms / 1000)
            for i in d..<n { wet[i] += y[i - d] * g }
        }
        return limit(wet, drive: 2.2)
    }

    /// The low roll of sparks swirling: deep filtered noise that swells and breathes.
    private static func rumble(_ length: Double) -> [Float] {
        let n = Int(rate * length), w = noise(n, seed: 5)
        var y = [Double](repeating: 0, count: n), lp1 = 0.0, lp2 = 0.0
        for i in 0..<n {
            let t = Double(i) / rate
            lp1 += 0.012 * (w[i] - lp1); lp2 += 0.012 * (lp1 - lp2)
            let breathe = 0.65 + 0.35 * sin(2 * .pi * 0.9 * t)
            let env = min(1, t / 0.5) * min(1, (length - t) / 0.6)
            y[i] = lp2 * breathe * env * (1 + 0.3 * sin(2 * .pi * 110 * t) * lp2)
        }
        return limit(y, drive: 1.5, peak: 0.7)
    }

    /// The reveal: air rising to a deep hit, with a low open chord blooming underneath. No bells.
    private static func reveal() -> [Float] {
        let n = Int(rate * 2.6)
        let rise = whoosh(1.1, from: 250, to: 7000, peakAt: 0.98).map(Double.init)
        var y = [Double](repeating: 0, count: n)
        for i in 0..<min(n, rise.count) { y[i] += rise[i] * 0.55 }
        let hit = Int(rate * 1.05)
        var p1 = 0.0, p2 = 0.0, p3 = 0.0, lp = 0.0
        for i in hit..<n {
            let t = Double(i - hit) / rate
            p1 += 2 * .pi * 55 / rate; p2 += 2 * .pi * 82.4 / rate; p3 += 2 * .pi * 110 / rate
            let boom = (sin(p1) + 0.5 * sin(2 * p1)) * exp(-t / 0.5)
            // A soft, slightly buzzy fifth that swells and hangs, like a film score holding a breath.
            let pad = (sin(p2) + 0.3 * sin(3 * p2) + 0.6 * sin(p3) + 0.2 * sin(3 * p3)) * min(1, t / 0.35) * exp(-t / 1.4)
            lp += 0.25 * (pad - lp)
            y[i] += boom * 1.0 + lp * 0.55
        }
        return limit(y, drive: 1.6, peak: 0.9)
    }

    /// A short, soft wooden tick.
    private static func tick() -> [Float] {
        let n = Int(rate * 0.09)
        return (0..<n).map { i in
            let t = Double(i) / rate
            let env = min(1, t / 0.002) * exp(-t / 0.018)
            return Float((sin(2 * .pi * 1250 * t) * 0.7 + sin(2 * .pi * 2500 * t) * 0.2) * env)
        }
    }

    private static func player(_ samples: [Float]) -> AVAudioPlayer? {
        try? AVAudioPlayer(data: wav(samples))
    }

    /// 16-bit mono PCM WAV in memory.
    private static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(samples.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + bytes)
        d.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(bytes)
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * 32767).littleEndian
            d.append(Data(bytes: &v, count: 2))
        }
        return d
    }
}
