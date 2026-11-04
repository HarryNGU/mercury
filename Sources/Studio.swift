// The studio: everything the editor adds on top of the cuts. Text, zoom moments, pictures, music,
// caption styles, the canvas and colour, and per clip speed and volume. Times are seconds in the
// original recording, so a title or a zoom stays on the moment it belongs to when the cuts around it
// change. EditTimeline turns the cuts into the pieces the video is made of; ReelRenderer draws each
// frame; ReelBuilder puts the video and the audio mix together for the preview and for saving.

import AppKit
import AVFoundation
import CoreImage

// MARK: - What can be added

struct Ranged: Codable, Equatable { var start: Double; var end: Double; var value: Double }

struct TextItem: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var text: String
    var start: Double
    var end: Double
    var x = 0.5                // centre, 0 left … 1 right
    var y = 0.2                // centre, 0 top … 1 bottom
    var size = 0.075           // of the frame's short side
    var font = "sans"          // sans, rounded, serif, mono, condensed, hand
    var weight = "heavy"       // regular, medium, bold, heavy
    var color = "FFFFFF"
    var style = "shadow"       // plain, shadow, outline, box
    var boxColor = "111111"
    var animation = "pop"      // none, fade, pop, slide, typewriter
}

struct ZoomItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var scale = 1.8
    var x = 0.5                // what to zoom towards, 0 left … 1 right
    var y = 0.5                // 0 top … 1 bottom
}

struct ImageItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var file: String
    var name: String
    var start: Double
    var end: Double
    var x = 0.86
    var y = 0.12
    var width = 0.18           // of the frame's width
    var opacity = 1.0
    var round = 0.0            // corner rounding, 0 … 0.5 of the picture's short side
}

/// A part of the recording blurred or pixelated, to hide a name, a face or a password.
struct BlurItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var x = 0.5, y = 0.5          // centre, in the recording's frame (0 top)
    var w = 0.3, h = 0.15         // size, as a share of the recording's frame
    var style = "blur"            // blur, pixelate, black
    var strength = 0.6
}

/// Another video on top: picture in picture, or covering the whole frame (B-roll).
struct VideoItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var file: String
    var name: String
    var start: Double          // seconds in the original recording
    var end: Double
    var trim = 0.0             // where in this video it starts playing
    var x = 0.75
    var y = 0.3
    var width = 0.42           // of the frame's width
    var round = 0.06
    var volume = 0.0           // its own sound; off unless you turn it up
    var full = false           // cover the whole frame
    var aspect = 16.0 / 9.0    // its width over its height, as it plays

    /// What changes the video's make-up, as opposed to where it sits.
    var timing: [String] { [file, "\(start)", "\(end)", "\(trim)", "\(volume)"] }
}

struct MusicTrack: Codable, Equatable {
    var file: String
    var name: String
    var volume = 0.22
    var duck = true            // quieter while you talk
    var fadeIn = 1.0
    var fadeOut = 2.0
}

struct CaptionStyle: Codable, Equatable {
    var preset = "classic"     // classic, karaoke, highlight, box, minimal
    var size = 1.0
    var color = "FFFFFF"
    var accent = "FFD60A"
    var font = "sans"
    var uppercase = false
    var wordsPerCue = 3
}

struct CanvasStyle: Codable, Equatable {
    var layout = "fit"         // fit, fill, framed
    var background = "blur"    // blur, color, gradient
    var color = "15151A"
    var color2 = "5B4BDB"
    var padding = 0.06
    var corner = 0.03
}

struct Look: Codable, Equatable {
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var warmth = 0.0           // -1 cool … 1 warm
    var vignette = 0.0
    var fadeIn = 0.0           // seconds from black
    var fadeOut = 0.0          // seconds to black
    var filter = "none"        // none, or one of StudioFilters.all
}

/// One-click film looks, from Core Image.
enum StudioFilters {
    static let all: [(String, String, String)] = [   // id, name, Core Image filter
        ("none", "None", ""), ("instant", "Instant", "CIPhotoEffectInstant"), ("chrome", "Chrome", "CIPhotoEffectChrome"),
        ("fade", "Faded", "CIPhotoEffectFade"), ("process", "Process", "CIPhotoEffectProcess"), ("transfer", "Transfer", "CIPhotoEffectTransfer"),
        ("tonal", "Tonal", "CIPhotoEffectTonal"), ("noir", "Noir", "CIPhotoEffectNoir"), ("sepia", "Sepia", "CISepiaTone"),
    ]
    static func apply(_ id: String, to img: CIImage) -> CIImage {
        guard id != "none", let name = all.first(where: { $0.0 == id })?.2, !name.isEmpty else { return img }
        return id == "sepia" ? img.applyingFilter(name, parameters: [kCIInputIntensityKey: 0.75]) : img.applyingFilter(name)
    }
}

struct AudioSettings: Codable, Equatable {
    var volume = 1.0
    var fadeIn = 0.0
    var fadeOut = 0.0
    var clean = false          // older setting, now Enhance speech
    var level = false          // even out quiet and loud phrases
    var micVolume = 1.0        // the first track: your microphone
    var sysVolume = 1.0        // the others: the computer's sound (a call, apps)
    var micEnhance = 0.0       // Enhance speech strength, 0 off … 1
    var sysEnhance = 0.0
    var echo = false           // remove your voice coming back through the computer's sound
    var polish = false         // EQ, compression and a limiter
    var loudness = "off"       // off, social, podcast, broadcast

    var recipe: AudioRecipe { AudioRecipe(micEnhance: micEnhance, sysEnhance: sysEnhance, echo: echo, polish: polish, target: target) }
    /// Integrated loudness to aim for, in LUFS.
    var target: Double? { ["social": -14, "podcast": -16, "broadcast": -23][loudness] }
}

struct ProgressBar: Codable, Equatable {
    var position = "bottom"    // top, bottom
    var color = ""             // empty: the caption accent
    var thickness = 0.008
}

// Every field falls back to its default, so edits saved by an older Mercury still open.
extension KeyedDecodingContainer {
    func v<T: Decodable>(_ k: Key, _ d: T) -> T { (try? decodeIfPresent(T.self, forKey: k)) ?? d }
}

extension TextItem {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = TextItem(text: "", start: 0, end: 0)
        id = c.v(.id, z.id); text = c.v(.text, z.text); start = c.v(.start, z.start); end = c.v(.end, z.end)
        x = c.v(.x, z.x); y = c.v(.y, z.y); size = c.v(.size, z.size); font = c.v(.font, z.font); weight = c.v(.weight, z.weight)
        color = c.v(.color, z.color); style = c.v(.style, z.style); boxColor = c.v(.boxColor, z.boxColor); animation = c.v(.animation, z.animation)
    }
}
extension ZoomItem {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = ZoomItem(start: 0, end: 0)
        id = c.v(.id, z.id); start = c.v(.start, z.start); end = c.v(.end, z.end); scale = c.v(.scale, z.scale); x = c.v(.x, z.x); y = c.v(.y, z.y)
    }
}
extension ImageItem {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = ImageItem(file: "", name: "", start: 0, end: 0)
        id = c.v(.id, z.id); file = c.v(.file, z.file); name = c.v(.name, z.name); start = c.v(.start, z.start); end = c.v(.end, z.end)
        x = c.v(.x, z.x); y = c.v(.y, z.y); width = c.v(.width, z.width); opacity = c.v(.opacity, z.opacity); round = c.v(.round, z.round)
    }
}
extension BlurItem {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = BlurItem(start: 0, end: 0)
        id = c.v(.id, z.id); start = c.v(.start, z.start); end = c.v(.end, z.end); x = c.v(.x, z.x); y = c.v(.y, z.y)
        w = c.v(.w, z.w); h = c.v(.h, z.h); style = c.v(.style, z.style); strength = c.v(.strength, z.strength)
    }
}
extension VideoItem {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = VideoItem(file: "", name: "", start: 0, end: 0)
        id = c.v(.id, z.id); file = c.v(.file, z.file); name = c.v(.name, z.name); start = c.v(.start, z.start); end = c.v(.end, z.end)
        trim = c.v(.trim, z.trim); x = c.v(.x, z.x); y = c.v(.y, z.y); width = c.v(.width, z.width); round = c.v(.round, z.round)
        volume = c.v(.volume, z.volume); full = c.v(.full, z.full); aspect = c.v(.aspect, z.aspect)
    }
}
extension MusicTrack {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = MusicTrack(file: "", name: "")
        file = c.v(.file, z.file); name = c.v(.name, z.name); volume = c.v(.volume, z.volume); duck = c.v(.duck, z.duck)
        fadeIn = c.v(.fadeIn, z.fadeIn); fadeOut = c.v(.fadeOut, z.fadeOut)
    }
}
extension CaptionStyle {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = CaptionStyle()
        preset = c.v(.preset, z.preset); size = c.v(.size, z.size); color = c.v(.color, z.color); accent = c.v(.accent, z.accent)
        font = c.v(.font, z.font); uppercase = c.v(.uppercase, z.uppercase); wordsPerCue = c.v(.wordsPerCue, z.wordsPerCue)
    }
}
extension CanvasStyle {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = CanvasStyle()
        layout = c.v(.layout, z.layout); background = c.v(.background, z.background); color = c.v(.color, z.color)
        color2 = c.v(.color2, z.color2); padding = c.v(.padding, z.padding); corner = c.v(.corner, z.corner)
    }
}
extension Look {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = Look()
        brightness = c.v(.brightness, z.brightness); contrast = c.v(.contrast, z.contrast); saturation = c.v(.saturation, z.saturation)
        warmth = c.v(.warmth, z.warmth); vignette = c.v(.vignette, z.vignette); fadeIn = c.v(.fadeIn, z.fadeIn); fadeOut = c.v(.fadeOut, z.fadeOut)
        filter = c.v(.filter, z.filter)
    }
}
extension AudioSettings {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = AudioSettings()
        volume = c.v(.volume, z.volume); fadeIn = c.v(.fadeIn, z.fadeIn); fadeOut = c.v(.fadeOut, z.fadeOut)
        clean = c.v(.clean, z.clean); level = c.v(.level, z.level)
        micVolume = c.v(.micVolume, z.micVolume); sysVolume = c.v(.sysVolume, z.sysVolume)
        micEnhance = c.v(.micEnhance, clean ? 0.8 : z.micEnhance); sysEnhance = c.v(.sysEnhance, z.sysEnhance)
        echo = c.v(.echo, z.echo); polish = c.v(.polish, z.polish); loudness = c.v(.loudness, z.loudness)
    }
}
extension ProgressBar {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = ProgressBar()
        position = c.v(.position, z.position); color = c.v(.color, z.color); thickness = c.v(.thickness, z.thickness)
    }
}

extension EditPlan {
    /// Takes a stretch of the original out of the video.
    mutating func cut(_ r: TimeSpan) {
        guard r.length > 0.01 else { return }
        removed = Cutter.merge(removed + [r])
        kept = kept.flatMap { Cutter.subtract(r, from: $0) }
    }

    /// Puts a stretch of the original back, even if it's silent.
    mutating func restore(_ r: TimeSpan) {
        guard r.length > 0.01 else { return }
        removed = removed.flatMap { Cutter.subtract(r, from: $0) }
        kept = Cutter.merge(kept + [r])
    }

    /// Whether going from one edit to the other changes which moments are in the video, or the sound,
    /// so the preview has to be put together again (anything else just redraws).
    func changesTiming(from o: EditPlan) -> Bool {
        maxPause != o.maxPause || removed != o.removed || kept != o.kept || speed != o.speed || splits != o.splits
            || clipSpeeds != o.clipSpeeds || clipVolumes != o.clipVolumes || clipMic != o.clipMic || clipSys != o.clipSys
            || music != o.music || audio != o.audio
            || videos.map(\.timing) != o.videos.map(\.timing)
    }
}

// MARK: - Colours and type

extension NSColor {
    convenience init(hex: String, alpha: CGFloat = 1) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFFFFFF
        self.init(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }
    var hex: String {
        guard let c = usingColorSpace(.sRGB) else { return "FFFFFF" }
        return String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

enum StudioType {
    static let families: [(String, String)] = [("sans", "Sans"), ("rounded", "Rounded"), ("serif", "Serif"), ("condensed", "Condensed"), ("mono", "Mono"), ("hand", "Marker")]

    static func font(_ family: String, size: CGFloat, weight: String) -> NSFont {
        let w: NSFont.Weight = switch weight { case "regular": .regular; case "medium": .medium; case "bold": .bold; default: .heavy }
        switch family {
        case "condensed": return NSFont.systemFont(ofSize: size, weight: w, width: .condensed)
        case "hand": return NSFont(name: w == .regular || w == .medium ? "MarkerFelt-Thin" : "MarkerFelt-Wide", size: size) ?? .systemFont(ofSize: size, weight: w)
        default:
            let base = NSFont.systemFont(ofSize: size, weight: w)
            let design: NSFontDescriptor.SystemDesign? = switch family { case "rounded": .rounded; case "serif": .serif; case "mono": .monospaced; default: nil }
            guard let design, let d = base.fontDescriptor.withDesign(design) else { return base }
            return NSFont(descriptor: d, size: size) ?? base
        }
    }

    /// Lays out text to a width, for drawing and for finding where a word sits.
    final class Block {
        let storage: NSTextStorage
        let layout = NSLayoutManager()
        let container: NSTextContainer
        let used: CGRect
        init(_ s: NSAttributedString, width: CGFloat) {
            storage = NSTextStorage(attributedString: s)
            container = NSTextContainer(size: NSSize(width: width, height: 10_000))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)
            used = layout.usedRect(for: container)
        }
        func rect(of range: NSRange) -> CGRect {
            layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        }
        func draw(at p: CGPoint) { layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: p) }
    }

    /// Draws into a transparent image the size given, with a top left origin like a page.
    static func picture(width: Int, height: Int, _ draw: () -> Void) -> CIImage? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    /// A text layer as a picture, with its style. `typed` shows only the first characters (typewriter).
    static func image(_ t: TextItem, frame: CGSize, typed: Int? = nil) -> CIImage? {
        let short = min(frame.width, frame.height)
        let size = max(8, short * t.size)
        let font = font(t.font, size: size, weight: t.weight)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineHeightMultiple = 0.92
        let full = t.text.isEmpty ? " " : t.text
        let shown = typed.map { String(full.prefix($0)) } ?? full
        let color = NSColor(hex: t.color)
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        if t.style == "shadow" {
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(0.6)
            sh.shadowBlurRadius = size * 0.22
            sh.shadowOffset = NSSize(width: 0, height: size * 0.05)
            attrs[.shadow] = sh
        }
        // Lay out the whole text so a typewriter reveal doesn't jump around.
        let maxW = frame.width * 0.9
        let measure = Block(NSAttributedString(string: full, attributes: attrs), width: maxW)
        let pad = t.style == "box" ? size * 0.42 : size * 0.3
        let w = Int(ceil(measure.used.width + pad * 2)), h = Int(ceil(measure.used.height + pad * 2))
        let block = Block(NSAttributedString(string: shown, attributes: attrs), width: maxW)
        let origin = CGPoint(x: pad - measure.used.minX, y: pad - measure.used.minY)
        return picture(width: w, height: h) {
            if t.style == "box" {
                NSColor(hex: t.boxColor, alpha: 0.88).setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: size * 0.28, yRadius: size * 0.28).fill()
            }
            if t.style == "outline" {
                let stroke = Block(NSAttributedString(string: shown, attributes: [.font: font, .paragraphStyle: para, .foregroundColor: NSColor.clear,
                                                                                .strokeColor: NSColor.black, .strokeWidth: 10]), width: maxW)
                stroke.draw(at: origin)
            }
            block.draw(at: origin)
        }
    }

    /// How big a text layer is in the frame, for the handles on the preview.
    static func box(_ t: TextItem, frame: CGSize) -> CGSize {
        let key = "\(t.hashValue)-\(frame.width)x\(frame.height)"
        boxLock.lock()
        if let b = boxes[key] { boxLock.unlock(); return b }
        boxLock.unlock()
        let b = image(t, frame: frame)?.extent.size ?? .zero
        boxLock.lock()
        if boxes.count > 200 { boxes.removeAll() }
        boxes[key] = b
        boxLock.unlock()
        return b
    }
    nonisolated(unsafe) private static var boxes: [String: CGSize] = [:]
    private static let boxLock = NSLock()
}

// MARK: - The pieces the video is made of

struct Piece: Equatable {
    var src: TimeSpan          // seconds in the original
    var out: TimeSpan          // seconds in the edited video
    var speed: Double
    var volume: Double
    var mic = 1.0              // this piece's level for your microphone
    var sys = 1.0              // … and for the computer's sound
    var afterCut = false       // the original jumps just before this piece
    var beforeCut = false      // … or just after it
}

/// What you see as one clip on the timeline: pieces joined by Mercury's own pause cuts, which show as
/// marks inside it. Your splits, your cuts and clips with their own speed or volume start a new one.
struct Clip: Equatable {
    var pieces: Range<Int>
    var src: TimeSpan          // from its first moment in the original to its last
    var out: TimeSpan
    var speed: Double
    var volume: Double
    var mic = 1.0
    var sys = 1.0
}

struct EditTimeline: Equatable {
    let pieces: [Piece]
    let clips: [Clip]
    var duration: Double { pieces.last?.out.end ?? 0 }

    init(spans: [TimeSpan], plan: EditPlan) {
        var edges = Set(plan.splits)
        for r in plan.clipSpeeds + plan.clipVolumes + plan.clipMic + plan.clipSys { edges.insert(r.start); edges.insert(r.end) }
        let sorted = edges.sorted()
        var list: [Piece] = []
        var t = 0.0
        for s in spans {
            let cuts = [s.start] + sorted.filter { $0 > s.start + 0.04 && $0 < s.end - 0.04 } + [s.end]
            for i in 0..<(cuts.count - 1) {
                let src = TimeSpan(start: cuts[i], end: cuts[i + 1])
                let mid = (src.start + src.end) / 2
                let speed = min(16, max(0.1, plan.speed * (plan.clipSpeeds.last { $0.start <= mid && mid < $0.end }?.value ?? 1)))
                func at(_ list: [Ranged]) -> Double { list.last { $0.start <= mid && mid < $0.end }?.value ?? 1 }
                let len = src.length / speed
                list.append(Piece(src: src, out: TimeSpan(start: t, end: t + len), speed: speed, volume: at(plan.clipVolumes),
                                  mic: at(plan.clipMic), sys: at(plan.clipSys)))
                t += len
            }
        }
        for i in list.indices {
            list[i].afterCut = i == 0 || abs(list[i - 1].src.end - list[i].src.start) > 0.001
            list[i].beforeCut = i == list.count - 1 || abs(list[i + 1].src.start - list[i].src.end) > 0.001
        }
        pieces = list

        var clips: [Clip] = []
        for (i, p) in list.enumerated() {
            if let last = clips.last, i > 0 {
                let prev = list[i - 1]
                let gap = TimeSpan(start: prev.src.end, end: p.src.start)
                let split = plan.splits.contains { abs($0 - p.src.start) < 0.001 }
                let yourCut = plan.removed.contains { min($0.end, gap.end) - max($0.start, gap.start) > 0.05 }
                let sameSound = abs(prev.volume - p.volume) < 0.001 && abs(prev.mic - p.mic) < 0.001 && abs(prev.sys - p.sys) < 0.001
                if !split && !yourCut && abs(prev.speed - p.speed) < 0.001 && sameSound {
                    clips[clips.count - 1].pieces = last.pieces.lowerBound..<(i + 1)
                    clips[clips.count - 1].src.end = p.src.end
                    clips[clips.count - 1].out.end = p.out.end
                    continue
                }
            }
            clips.append(Clip(pieces: i..<(i + 1), src: p.src, out: p.out, speed: p.speed, volume: p.volume, mic: p.mic, sys: p.sys))
        }
        self.clips = clips
    }

    /// The moments of the original shown between two edited times.
    func sourceRanges(from a: Double, to b: Double) -> [TimeSpan] {
        var out: [TimeSpan] = []
        for p in pieces {
            let o0 = max(a, p.out.start), o1 = min(b, p.out.end)
            guard o1 - o0 > 0.0005 else { continue }
            let r = TimeSpan(start: p.src.start + (o0 - p.out.start) * p.speed, end: p.src.start + (o1 - p.out.start) * p.speed)
            if let last = out.last, abs(last.end - r.start) < 0.001 { out[out.count - 1].end = r.end } else { out.append(r) }
        }
        return out
    }

    func clipIndex(at t: Double) -> Int? {
        guard let i = index(at: t) else { return nil }
        return clips.firstIndex { $0.pieces.contains(i) }
    }

    /// The piece playing at an edited time (the later one exactly on a join).
    func index(at t: Double) -> Int? {
        guard !pieces.isEmpty else { return nil }
        var lo = 0, hi = pieces.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if pieces[mid].out.start <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The original moment shown at an edited time. `preferEnd` picks the end of the earlier piece on a join.
    func source(at t: Double, preferEnd: Bool = false) -> Double {
        guard var i = index(at: t) else { return t }
        if preferEnd, i > 0, abs(pieces[i].out.start - t) < 1e-6 { i -= 1 }
        let p = pieces[i]
        return p.src.start + (min(max(t, p.out.start), p.out.end) - p.out.start) * p.speed
    }

    /// Where an original moment lands in the edit (nil if it was cut).
    func output(at s: Double) -> Double? {
        for p in pieces where s >= p.src.start - 1e-6 && s <= p.src.end + 1e-6 { return p.out.start + (min(max(s, p.src.start), p.src.end) - p.src.start) / p.speed }
        return nil
    }

    /// Where an original moment lands, or the next moment that's still in the edit.
    func outputOrNext(_ s: Double) -> Double {
        if let o = output(at: s) { return o }
        return pieces.first { $0.src.start >= s }?.out.start ?? duration
    }

    /// The stretch of the edit covering a stretch of the original, from its first kept moment to its last.
    func outputSpan(of r: TimeSpan) -> TimeSpan? {
        let parts = outputRanges(of: r)
        guard let a = parts.first?.start, let b = parts.last?.end, b > a else { return nil }
        return TimeSpan(start: a, end: b)
    }

    /// The bits of the edit that come from a stretch of the original.
    func outputRanges(of r: TimeSpan) -> [TimeSpan] {
        var out: [TimeSpan] = []
        for p in pieces where p.src.end > r.start && p.src.start < r.end {
            let s0 = max(r.start, p.src.start), s1 = min(r.end, p.src.end)
            let o = TimeSpan(start: p.out.start + (s0 - p.src.start) / p.speed, end: p.out.start + (s1 - p.src.start) / p.speed)
            if let last = out.last, o.start - last.end < 0.001 { out[out.count - 1].end = o.end } else { out.append(o) }
        }
        return out
    }
}

// MARK: - Drawing each frame

private func ease(_ x: Double) -> Double { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
private func easeOut(_ x: Double) -> Double { let t = min(1, max(0, x)); return 1 - pow(1 - t, 3) }
private func easeOutBack(_ x: Double) -> Double { let t = min(1, max(0, x)), c = 1.6; return 1 + (c + 1) * pow(t - 1, 3) + c * pow(t - 1, 2) }

extension CIImage {
    /// The same picture, see-through by `a` (0 … 1).
    func faded(_ a: Double) -> CIImage {
        if a >= 0.999 { return self }
        let v = CGFloat(max(0, a))
        return applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: v, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: v, z: 0, w: 0),
                                                           "inputBVector": CIVector(x: 0, y: 0, z: v, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: v)])
    }
}

/// Draws each frame: the recording laid out on its canvas, then pictures, text, captions and the
/// progress bar. Shared with AVFoundation's render threads, so what it reads is locked; the editor
/// hands it a new edit while you work and the next frame shows it, without rebuilding the video.
final class ReelRenderer: @unchecked Sendable {
    let size: CGSize
    let timeline: EditTimeline
    let original: Bool
    private let transcript: [Word]
    private var plan: EditPlan
    private var cues: [Cue] = []
    private var captionCache: [String: CIImage] = [:]
    private var textCache: [String: CIImage] = [:]
    private var pictureCache: [String: CIImage] = [:]
    private let lock = NSLock()

    init(size: CGSize, plan: EditPlan, timeline: EditTimeline, words: [Word], original: Bool) {
        self.size = size
        self.plan = plan
        self.timeline = timeline
        self.transcript = words
        self.original = original
        cues = Captions.cues(plan.words ?? words, timeline: timeline, perCue: plan.captionStyle.wordsPerCue)
    }

    /// A new edit with the same timing: the next frame drawn shows it.
    func update(_ p: EditPlan) {
        lock.lock(); defer { lock.unlock() }
        if p.words != plan.words || p.captionStyle.wordsPerCue != plan.captionStyle.wordsPerCue {
            cues = Captions.cues(p.words ?? transcript, timeline: timeline, perCue: p.captionStyle.wordsPerCue)
            captionCache.removeAll()
        }
        if p.captionStyle != plan.captionStyle || p.captionPosition != plan.captionPosition { captionCache.removeAll() }
        plan = p
    }

    func frame(_ src: CIImage, at t: Double, overlays: [UUID: CIImage] = [:]) -> CIImage {
        lock.lock()
        let p = plan, cues = self.cues
        lock.unlock()
        let W = size.width, H = size.height
        let out = CGRect(origin: .zero, size: size)
        let s = timeline.source(at: t)
        var img0 = src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY))
        let e = img0.extent

        // Colour.
        let l = p.look
        if l.brightness != 0 || l.contrast != 1 || l.saturation != 1 {
            img0 = img0.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: l.brightness * 0.25, kCIInputContrastKey: l.contrast,
                                                                       kCIInputSaturationKey: l.saturation])
        }
        if abs(l.warmth) > 0.01 {
            img0 = img0.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0),
                                                                            "inputTargetNeutral": CIVector(x: 6500 + 2600 * l.warmth, y: 0)])
        }

        img0 = StudioFilters.apply(l.filter, to: img0).cropped(to: e)

        // Blur boxes, on the recording itself so they stay put through zooms and layouts.
        for b in p.blurs where s >= b.start && s < b.end {
            let r = CGRect(x: (b.x - b.w / 2) * e.width, y: (1 - b.y - b.h / 2) * e.height, width: b.w * e.width, height: b.h * e.height).intersection(e).integral
            guard r.width > 2, r.height > 2 else { continue }
            let amount = max(4, min(e.width, e.height) * 0.04 * (0.3 + b.strength))
            let hidden: CIImage
            switch b.style {
            case "black": hidden = CIImage(color: .black)
            case "pixelate": hidden = img0.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: amount, kCIInputCenterKey: CIVector(x: r.minX, y: r.minY)])
            default: hidden = img0.clampedToExtent().applyingGaussianBlur(sigma: Double(amount) * 0.8)
            }
            img0 = hidden.cropped(to: r).composited(over: img0)
        }

        // Zoom moments: crop in towards the point, easing in and out.
        let (z, fx, fy) = zoom(at: t, p)
        var content = img0.cropped(to: e)
        if z > 1.001 {
            let cw = e.width / z, ch = e.height / z
            let cx = min(max(fx * e.width, cw / 2), e.width - cw / 2)
            let cy = min(max((1 - fy) * e.height, ch / 2), e.height - ch / 2)
            let r = CGRect(x: cx - cw / 2, y: cy - ch / 2, width: cw, height: ch)
            content = img0.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY).concatenating(CGAffineTransform(scaleX: z, y: z)))
                .cropped(to: e)
        }

        // Background.
        var img: CIImage
        switch p.canvas.background {
        case "color":
            img = CIImage(color: CIColor(color: NSColor(hex: p.canvas.color)) ?? .black).cropped(to: out)
        case "gradient":
            img = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: H), "inputPoint1": CIVector(x: W, y: 0),
                "inputColor0": CIColor(color: NSColor(hex: p.canvas.color)) ?? .black, "inputColor1": CIColor(color: NSColor(hex: p.canvas.color2)) ?? .black,
            ])?.outputImage?.cropped(to: out) ?? CIImage(color: .black).cropped(to: out)
        default:
            let fill = max(W / e.width, H / e.height), small = fill * 0.25
            img = content.transformed(by: CGAffineTransform(scaleX: small, y: small))
                .clampedToExtent()
                .applyingGaussianBlur(sigma: 14)
                .transformed(by: CGAffineTransform(scaleX: 4, y: 4))
                .transformed(by: CGAffineTransform(translationX: (W - e.width * fill) / 2, y: (H - e.height * fill) / 2))
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0.04, kCIInputSaturationKey: 1.25])
                .cropped(to: out)
        }

        // The recording, laid out.
        let fit = min(W / e.width, H / e.height), fill = max(W / e.width, H / e.height)
        let short = min(W, H)
        if p.canvas.layout == "framed" {
            let pad = short * p.canvas.padding
            let k = min((W - pad * 2) / e.width, (H - pad * 2) / e.height)
            let rect = CGRect(x: (W - e.width * k) / 2, y: (H - e.height * k) / 2, width: e.width * k, height: e.height * k).integral
            let radius = short * p.canvas.corner
            let placed = content.transformed(by: CGAffineTransform(scaleX: rect.width / e.width, y: rect.height / e.height)
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
            let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: rect), "inputRadius": radius,
                                                                                 "inputColor": CIColor.white])?.outputImage
            let shadow = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: rect.offsetBy(dx: 0, dy: -short * 0.012)),
                                                                                   "inputRadius": radius, "inputColor": CIColor(red: 0, green: 0, blue: 0, alpha: 0.5)])?
                .outputImage?.applyingGaussianBlur(sigma: Double(short) * 0.022)
            if let shadow { img = shadow.composited(over: img).cropped(to: out) }
            if let mask {
                img = placed.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: mask])
            } else {
                img = placed.composited(over: img)
            }
        } else {
            let zoomAll = original ? 1 : max(1, p.zoom)
            let k = (p.canvas.layout == "fill" ? fill : fit) * zoomAll
            let sw = e.width * k, sh = e.height * k
            let x = sw > W ? -(sw - W) * p.focusX : (W - sw) / 2
            let y = sh > H ? -(sh - H) * (1 - p.focusY) : (H - sh) / 2
            img = content.transformed(by: CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: x, y: y)))
                .cropped(to: out).composited(over: img)
        }
        if l.vignette > 0.01 {
            img = img.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: l.vignette * 1.6, kCIInputRadiusKey: 1.6]).cropped(to: out)
        }

        // Pictures.
        for item in p.images where s >= item.start && s < item.end {
            guard let pic = picture(item) else { continue }
            let w = W * item.width, k = w / max(1, pic.extent.width)
            let h = pic.extent.height * k
            var placed = pic.transformed(by: CGAffineTransform(scaleX: k, y: k))
            if item.round > 0, let m = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: placed.extent), "inputRadius": min(w, h) * item.round, "inputColor": CIColor.white])?.outputImage {
                placed = placed.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: m])
            }
            placed = placed.transformed(by: CGAffineTransform(translationX: W * item.x - w / 2, y: H * (1 - item.y) - h / 2))
            img = placed.faded(item.opacity * appear(item.start, item.end, t: t, fade: 0.25)).composited(over: img)
        }

        // Videos on top.
        for item in p.videos where s >= item.start && s < item.end {
            guard let v = overlays[item.id] else { continue }
            let vx = v.transformed(by: CGAffineTransform(translationX: -v.extent.minX, y: -v.extent.minY))
            let ve = vx.extent
            guard ve.width > 0, ve.height > 0 else { continue }
            if item.full {
                let k = max(W / ve.width, H / ve.height)
                img = vx.transformed(by: CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: (W - ve.width * k) / 2, y: (H - ve.height * k) / 2)))
                    .cropped(to: out).faded(appear(item.start, item.end, t: t, fade: 0.2)).composited(over: img)
                continue
            }
            let w = W * item.width, k = w / ve.width, h = ve.height * k
            let rect = CGRect(x: W * item.x - w / 2, y: H * (1 - item.y) - h / 2, width: w, height: h)
            var placed = vx.transformed(by: CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
            let radius = min(w, h) * item.round
            if radius > 0, let m = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: rect), "inputRadius": radius, "inputColor": CIColor.white])?.outputImage {
                placed = placed.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: m])
            }
            let a = appear(item.start, item.end, t: t, fade: 0.2)
            if let sh = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: rect.offsetBy(dx: 0, dy: -short * 0.01)),
                                                                                  "inputRadius": radius, "inputColor": CIColor(red: 0, green: 0, blue: 0, alpha: 0.45)])?.outputImage {
                img = sh.applyingGaussianBlur(sigma: Double(short) * 0.018).faded(a).composited(over: img).cropped(to: out)
            }
            img = placed.faded(a).composited(over: img)
        }

        // Text.
        for item in p.texts where s >= item.start - 0.001 && s < item.end {
            guard let span = timeline.outputSpan(of: TimeSpan(start: item.start, end: item.end)) else { continue }
            let inDur = min(0.4, span.length / 3), outDur = min(0.3, span.length / 4)
            let pin = inDur > 0 ? (t - span.start) / inDur : 1, pout = outDur > 0 ? (span.end - t) / outDur : 1
            var alpha = 1.0, scale = 1.0, dy = 0.0
            var typed: Int?
            switch item.animation {
            case "fade": alpha = min(1, pin) * min(1, pout)
            case "pop": scale = 0.55 + 0.45 * easeOutBack(pin); alpha = min(1, pin * 2) * min(1, pout)
            case "slide": dy = -(1 - easeOut(pin)) * Double(H) * 0.05; alpha = min(1, pin) * min(1, pout)
            case "typewriter":
                let n = item.text.count
                let dur = min(1.6, max(0.4, span.length * 0.4), Double(n) * 0.06)
                typed = min(n, Int(ceil(Double(n) * max(0, t - span.start) / max(0.05, dur))))
                alpha = min(1, pout)
            default: break
            }
            guard let pic = text(item, typed: typed) else { continue }
            let cx = W * item.x, cy = H * (1 - item.y) + dy
            let placed = pic.transformed(by: CGAffineTransform(translationX: -pic.extent.width / 2, y: -pic.extent.height / 2)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: cx, y: cy)))
            img = placed.faded(alpha).composited(over: img)
        }

        // Captions.
        if p.captions, let i = cueIndex(cues, t) {
            let cue = cues[i]
            let active = cue.words.lastIndex { t >= $0.start } ?? 0
            if let cap = caption(i, cue, active: active, p.captionStyle) {
                let cy: CGFloat = switch p.captionPosition {
                case "top": H * 0.80
                case "middle": H * 0.5
                default: H * (H > W * 1.2 ? 0.2 : 0.12)
                }
                img = cap.transformed(by: CGAffineTransform(translationX: (W - cap.extent.width) / 2, y: cy - cap.extent.height / 2)).composited(over: img)
            }
        }

        // Progress bar.
        if let bar = p.progressBar, timeline.duration > 0 {
            let h = max(3, H * bar.thickness), w = W * min(1, t / timeline.duration)
            let color = NSColor(hex: bar.color.isEmpty ? p.captionStyle.accent : bar.color)
            let rect = CGRect(x: 0, y: bar.position == "top" ? H - h : 0, width: w, height: h)
            img = CIImage(color: CIColor(color: color) ?? .white).cropped(to: rect).composited(over: img)
        }

        // Fade from and to black.
        let fadeIn = l.fadeIn > 0 ? t / l.fadeIn : 1, fadeOut = l.fadeOut > 0 ? (timeline.duration - t) / l.fadeOut : 1
        let a = min(1, max(0, min(fadeIn, fadeOut)))
        if a < 0.999 { img = img.faded(a).composited(over: CIImage(color: .black).cropped(to: out)) }
        return img.cropped(to: out)
    }

    /// Zoom level and where it points at an edited time. Each moment eases in over half a second and out
    /// again, like a camera push; between two close moments it glides from one to the next.
    private func zoom(at t: Double, _ p: EditPlan) -> (Double, Double, Double) {
        var best: (Double, Double, Double, Double) = (1, 0.5, 0.5, 0)
        for z in p.zooms {
            guard let span = timeline.outputSpan(of: TimeSpan(start: z.start, end: z.end)) else { continue }
            let ramp = min(0.55, span.length / 3)
            let w = ramp > 0 ? min(ease((t - span.start) / ramp), ease((span.end - t) / ramp)) : (t >= span.start && t < span.end ? 1 : 0)
            if w > best.3 { best = (1 + (z.scale - 1) * w, z.x, z.y, w) }
        }
        return (best.0, best.1, best.2)
    }

    private func appear(_ start: Double, _ end: Double, t: Double, fade: Double) -> Double {
        guard let span = timeline.outputSpan(of: TimeSpan(start: start, end: end)) else { return 1 }
        // A picture that's there from the first frame or until the last one doesn't fade there.
        let fin = span.start < 0.01 ? 1 : (t - span.start) / fade
        let fout = span.end > timeline.duration - 0.01 ? 1 : (span.end - t) / fade
        return min(1, max(0, min(fin, fout)))
    }

    private func cueIndex(_ cues: [Cue], _ t: Double) -> Int? {
        var lo = 0, hi = cues.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if t < cues[mid].start { hi = mid - 1 } else if t >= cues[mid].end { lo = mid + 1 } else { return mid }
        }
        return nil
    }

    private func caption(_ i: Int, _ cue: Cue, active: Int, _ style: CaptionStyle) -> CIImage? {
        let moving = style.preset == "karaoke" || style.preset == "highlight"
        let key = "\(i)-\(moving ? active : -1)"
        lock.lock()
        if let c = captionCache[key] { lock.unlock(); return c }
        lock.unlock()
        let c = Captions.image(cue, active: moving ? active : nil, style: style, frame: size)
        lock.lock()
        if captionCache.count > 40 { captionCache.removeAll() }
        captionCache[key] = c
        lock.unlock()
        return c
    }

    private func text(_ item: TextItem, typed: Int?) -> CIImage? {
        let key = "\(item.hashValue)-\(typed ?? -1)"
        lock.lock()
        if let c = textCache[key] { lock.unlock(); return c }
        lock.unlock()
        let c = StudioType.image(item, frame: size, typed: typed)
        lock.lock()
        if textCache.count > 80 { textCache.removeAll() }
        textCache[key] = c
        lock.unlock()
        return c
    }

    private func picture(_ item: ImageItem) -> CIImage? {
        lock.lock()
        if let c = pictureCache[item.file] { lock.unlock(); return c }
        lock.unlock()
        guard let c = CIImage(contentsOf: URL(fileURLWithPath: item.file)) else { return nil }
        let pic = c.transformed(by: CGAffineTransform(translationX: -c.extent.minX, y: -c.extent.minY))
        lock.lock()
        pictureCache[item.file] = pic
        lock.unlock()
        return pic
    }
}

// MARK: - Mixing the videos

/// Tells the compositor which tracks to draw and who draws them.
final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let main: CMPersistentTrackID
    let overlays: [UUID: (CMPersistentTrackID, CGAffineTransform)]
    let renderer: ReelRenderer
    let size: CGSize

    init(range: CMTimeRange, main: CMPersistentTrackID, overlays: [UUID: (CMPersistentTrackID, CGAffineTransform)], renderer: ReelRenderer, size: CGSize) {
        timeRange = range
        self.main = main
        self.overlays = overlays
        self.renderer = renderer
        self.size = size
        requiredSourceTrackIDs = ([main] + overlays.values.map(\.0)).map { NSNumber(value: $0) }
    }
}

/// Draws each frame from the recording plus any videos on top, through ReelRenderer.
final class StudioCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "bubble.studio.compositor")
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ r: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            guard let ins = r.videoCompositionInstruction as? StudioInstruction, let out = r.renderContext.newPixelBuffer() else {
                r.finish(with: NSError(domain: "Bubble", code: 3)); return
            }
            let main = r.sourceFrame(byTrackID: ins.main).map { CIImage(cvPixelBuffer: $0) } ?? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: ins.size))
            var overlays: [UUID: CIImage] = [:]
            for (id, (track, transform)) in ins.overlays {
                if let px = r.sourceFrame(byTrackID: track) { overlays[id] = CIImage(cvPixelBuffer: px).oriented(Self.orientation(transform)) }
            }
            let img = ins.renderer.frame(main, at: r.compositionTime.seconds, overlays: overlays)
            ci.render(img, to: out, bounds: CGRect(origin: .zero, size: ins.size), colorSpace: space)
            r.finish(withComposedVideoFrame: out)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    /// Phone videos are stored sideways with a note to turn them.
    private static func orientation(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
        if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 { return .right }
        if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 { return .left }
        if t.a == -1 && t.d == -1 { return .down }
        return .up
    }
}

// MARK: - Putting the video together

enum ReelBuilder {
    struct Built {
        let composition: AVComposition
        let video: AVVideoComposition
        let audioMix: AVAudioMix?
        let duration: Double
        let renderSize: CGSize
        let renderer: ReelRenderer
    }

    /// `voiced`: where someone talks in the original, so music can dip under it.
    static func build(url: URL, timeline: EditTimeline, plan: EditPlan, size: ReelSize, resolution: Double = 1,
                      words: [Word]?, voiced: [TimeSpan], levels: [Float] = [], hop: Double = 0.02) async throws -> Built {
        let asset = AVURLAsset(url: url)
        let comp = AVMutableComposition()
        guard let vSrc = try await asset.loadTracks(withMediaType: .video).first,
              let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "Bubble", code: 1, userInfo: [NSLocalizedDescriptionKey: "This recording has no video."])
        }
        var aSrcs = try await asset.loadTracks(withMediaType: .audio)
        // The sound studio's tracks in place of the recorded ones, once they're ready. (Kept: tracks hold assets weakly.)
        let processed = plan.audio.recipe.isEmpty ? nil : AudioStudio.load(url, plan.audio.recipe)
        var studioAssets: [AVURLAsset] = []
        for i in aSrcs.indices {
            guard let f = processed?.files["\(i)"] else { continue }
            let a = AVURLAsset(url: URL(fileURLWithPath: f))
            studioAssets.append(a)
            if let t = try? await a.loadTracks(withMediaType: .audio).first { aSrcs[i] = t }
        }
        let aDsts = aSrcs.compactMap { _ in comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        func ct(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 60_000) }
        var cursor = CMTime.zero
        for piece in timeline.pieces {
            let r = CMTimeRange(start: ct(piece.src.start), end: ct(piece.src.end))
            try v.insertTimeRange(r, of: vSrc, at: cursor)
            for (src, dst) in zip(aSrcs, aDsts) { try? dst.insertTimeRange(r, of: src, at: cursor) }
            if abs(piece.speed - 1) > 0.001 {
                let to = ct(piece.src.length / piece.speed)
                comp.scaleTimeRange(CMTimeRange(start: cursor, duration: r.duration), toDuration: to)
                cursor = cursor + to
            } else {
                cursor = cursor + r.duration
            }
        }
        let duration = cursor.seconds

        // Sound: each piece's volume, tiny fades at the cuts so they don't click, fades at the ends.
        var params: [AVMutableAudioMixInputParameters] = []
        let a = plan.audio
        func envelope(_ t: Double, fadeIn: Double, fadeOut: Double) -> Double {
            min(1, fadeIn > 0 ? t / fadeIn : 1, fadeOut > 0 ? (duration - t) / fadeOut : 1)
        }
        let r = 0.012
        // Evening out: each phrase's own gain, eased over 80 ms at its edges; pauses keep the lower neighbour's.
        let gains = plan.audio.level && !levels.isEmpty ? AudioStudio.phraseGains(levels: levels, hop: hop, voiced: voiced) : []
        func level(_ s: Double) -> Double {
            guard !gains.isEmpty else { return 1 }
            var lo = 0, hi = gains.count - 1
            while lo < hi { let m = (lo + hi + 1) / 2; if gains[m].0.start <= s { lo = m } else { hi = m - 1 } }
            let (span, g) = gains[lo]
            if s >= span.start && s <= span.end {
                let edge = min(1, min(s - span.start, span.end - s) / 0.08)
                let quiet = min(g, lo + 1 < gains.count ? gains[lo + 1].1 : g, lo > 0 ? gains[lo - 1].1 : g)
                return quiet + (g - quiet) * edge
            }
            return min(g, lo + 1 < gains.count ? gains[lo + 1].1 : g)
        }
        /// track 0 is your microphone, the rest the computer's sound.
        func voice(_ t: Double, track: Int) -> Double {
            guard let i = timeline.index(at: t) else { return 0 }
            let p = timeline.pieces[i]
            var g = p.volume * (track == 0 ? p.mic : p.sys) * a.volume * level(timeline.source(at: t))
            if p.afterCut { g *= min(1, max(0, (t - p.out.start) / r)) }
            if p.beforeCut { g *= min(1, max(0, (p.out.end - t) / r)) }
            return g * max(0, envelope(t, fadeIn: a.fadeIn, fadeOut: a.fadeOut))
        }
        var marks: [Double] = [0, duration, a.fadeIn, duration - a.fadeOut]
        for p in timeline.pieces { marks += [p.out.start, p.out.start + r, p.out.end - r, p.out.end - 0.0001] }
        for (span, _) in gains {
            for o in timeline.outputRanges(of: span) { marks += [o.start, o.start + 0.08, o.end - 0.08, o.end] }
        }
        // Your mic and the computer's sound each at their own volume (and each clip's own mix of them),
        // the pair brought to the loudness target.
        let micPoints = points(marks, duration) { voice($0, track: 0) }, sysPoints = points(marks, duration) { voice($0, track: 1) }
        let volumes = [plan.audio.micVolume, plan.audio.sysVolume]
        let norm = plan.audio.target.flatMap { t in processed.map { AudioStudio.gain(to: t, $0, volumes: volumes) } } ?? 1
        for (i, dst) in aDsts.enumerated() {
            let ip = AVMutableAudioMixInputParameters(track: dst)
            let f = volumes[min(i, 1)] * norm
            ramps((i == 0 ? micPoints : sysPoints).map { ($0.0, $0.1 * f) }, into: ip)
            params.append(ip)
        }
        _ = studioAssets

        // Music, looped to the length, dipping while you talk.
        // (The song's asset is kept in a variable: a track only holds on to its asset weakly.)
        let song = plan.music.map { AVURLAsset(url: URL(fileURLWithPath: $0.file)) }
        if let m = plan.music, let song, FileManager.default.fileExists(atPath: m.file),
           let mSrc = try? await song.loadTracks(withMediaType: .audio).first,
           let mDst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let mLen = (try? await mSrc.load(.timeRange).duration.seconds) ?? 0
            if mLen > 0.5 {
                var at = 0.0
                while at < duration - 0.05 {
                    let len = min(mLen, duration - at)
                    do { try mDst.insertTimeRange(CMTimeRange(start: .zero, duration: ct(len)), of: mSrc, at: ct(at)) } catch { log("music: \(error.localizedDescription)"); break }
                    at += len
                }
                let talk = Cutter.merge(voiced.flatMap { timeline.outputRanges(of: $0) }.map { TimeSpan(start: $0.start, end: $0.end + 0.6) })
                let ramp = 0.3
                func music(_ t: Double) -> Double {
                    var duck = 1.0
                    if m.duck {
                        for s in talk where t > s.start - ramp && t < s.end + ramp {
                            let inside = min(1, max(0, min((t - (s.start - ramp)) / ramp, (s.end + ramp - t) / ramp)))
                            duck = min(duck, 1 - 0.7 * inside)
                        }
                    }
                    return m.volume * duck * max(0, envelope(t, fadeIn: m.fadeIn, fadeOut: m.fadeOut))
                }
                var mm: [Double] = [0, duration, m.fadeIn, duration - m.fadeOut]
                if m.duck { for s in talk { mm += [s.start - ramp, s.start, s.end, s.end + ramp] } }
                let ip = AVMutableAudioMixInputParameters(track: mDst)
                ramps(points(mm, duration, music), into: ip)
                params.append(ip)
            }
        }
        // Videos on top, each on its own track, laid where it shows in the edit.
        var overlayAssets: [AVURLAsset] = []   // kept: tracks hold their assets weakly
        var overlayTracks: [UUID: (CMPersistentTrackID, CGAffineTransform)] = [:]
        for item in plan.videos where FileManager.default.fileExists(atPath: item.file) {
            guard let span = timeline.outputSpan(of: TimeSpan(start: item.start, end: item.end)) else { continue }
            let oa = AVURLAsset(url: URL(fileURLWithPath: item.file))
            overlayAssets.append(oa)
            guard let ov = try? await oa.loadTracks(withMediaType: .video).first,
                  let len = try? await oa.load(.duration).seconds, len > item.trim + 0.05,
                  let dst = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let use = min(span.length, len - item.trim)
            let r = CMTimeRange(start: ct(item.trim), duration: ct(use))
            do { try dst.insertTimeRange(r, of: ov, at: ct(span.start)) } catch { log("overlay video: \(error.localizedDescription)"); continue }
            overlayTracks[item.id] = (dst.trackID, (try? await ov.load(.preferredTransform)) ?? .identity)
            if item.volume > 0.001, let oaud = try? await oa.loadTracks(withMediaType: .audio).first,
               let adst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? adst.insertTimeRange(r, of: oaud, at: ct(span.start))
                let ip = AVMutableAudioMixInputParameters(track: adst)
                let f = min(0.15, use / 4)
                ramps([(span.start, 0), (span.start + f, item.volume), (span.start + use - f, item.volume), (span.start + use, 0)], into: ip)
                params.append(ip)
            }
        }
        _ = overlayAssets

        let mix = AVMutableAudioMix()
        mix.inputParameters = params

        let natural = try await vSrc.load(.naturalSize)
        var render = size.render(source: natural)
        if resolution != 1 {
            func even(_ x: CGFloat) -> CGFloat { (x * resolution / 2).rounded() * 2 }
            render = CGSize(width: even(render.width), height: even(render.height))
        }
        var p = plan
        if size == .original { p.zoom = 1 }
        let renderer = ReelRenderer(size: render, plan: p, timeline: timeline, words: words ?? [], original: size == .original)
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = StudioCompositor.self
        vc.instructions = [StudioInstruction(range: CMTimeRange(start: .zero, duration: comp.duration), main: v.trackID,
                                             overlays: overlayTracks, renderer: renderer, size: render)]
        vc.renderSize = render
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        return Built(composition: comp, video: vc, audioMix: mix, duration: duration, renderSize: render, renderer: renderer)
    }

    /// A volume curve sampled at the moments it bends.
    private static func points(_ marks: [Double], _ duration: Double, _ f: (Double) -> Double) -> [(Double, Double)] {
        let ts = Array(Set(marks.filter { $0 >= 0 && $0 <= duration }.map { ($0 * 10_000).rounded() / 10_000 })).sorted()
        return ts.map { ($0, max(0, f($0))) }
    }

    private static func ramps(_ pts: [(Double, Double)], into ip: AVMutableAudioMixInputParameters) {
        guard let first = pts.first else { return }
        ip.setVolume(Float(first.1), at: .zero)
        for (a, b) in zip(pts, pts.dropFirst()) where b.0 - a.0 > 0.0005 {
            ip.setVolumeRamp(fromStartVolume: Float(a.1), toEndVolume: Float(b.1),
                             timeRange: CMTimeRange(start: CMTime(seconds: a.0, preferredTimescale: 60_000), end: CMTime(seconds: b.0, preferredTimescale: 60_000)))
        }
    }

    /// Writes to a hidden file first and only gives it the reel's name once it's complete, so a save that's
    /// interrupted (Mercury quit, Mac asleep, disk full) never leaves a broken video that looks finished.
    static func export(_ b: Built, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let partial = url.deletingLastPathComponent().appendingPathComponent(".saving-\(UUID().uuidString).mp4")
        do {
            try await write(b, to: partial, progress: progress)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: partial, to: url)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// Clears out pieces of saves that never finished.
    static func removeUnfinished(in folder: URL) {
        for f in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.hasPrefix(".saving-") { try? FileManager.default.removeItem(at: f) }
    }

    private static func write(_ b: Built, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: b.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "Bubble", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't start the export."])
        }
        session.videoComposition = b.video
        session.audioMix = b.audioMix
        session.audioTimePitchAlgorithm = .spectral
        let watcher = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: url, as: .mp4)
    }
}
