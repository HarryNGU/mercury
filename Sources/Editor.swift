// The reel editor: a video editor for one recording, in the spirit of VEED. Bubble cuts the pauses straight
// away and writes captions; you trim, split and speed up clips on the timeline, cut words from the
// transcript, add text, zoom moments, pictures and music, style the canvas and colour, or ask Claude in
// the chat ("cut the part about pricing", "add a title"). Saving writes the videos to Bubble Recordings/Reels.

import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatLine: Codable, Identifiable, Equatable {
    var id = UUID()
    var fromUser: Bool
    var text: String
}

/// What's picked on the timeline or the preview.
enum Selection: Equatable {
    case none
    case piece(Double)     // the clip starting at this moment of the original
    case text(UUID)
    case video(UUID)
    case blur(UUID)
    case range             // a stretch dragged out on the timeline (see ReelEditor.range)
    case zoom(UUID)
    case image(UUID)
    case music
}

/// The tools down the left of the editor.
enum StudioTool: String, CaseIterable, Identifiable {
    case edit, text, captions, transcript, zoom, media, audio, canvas, colour, claude
    var id: String { rawValue }
    var label: String {
        switch self {
        case .edit: "Edit"; case .text: "Text"; case .captions: "Subtitles"; case .transcript: "Transcript"; case .zoom: "Zoom"
        case .media: "Media"; case .audio: "Audio"; case .canvas: "Canvas"; case .colour: "Colour"; case .claude: "Claude"
        }
    }
    var icon: String {
        switch self {
        case .edit: "scissors"; case .text: "textformat"; case .captions: "captions.bubble"; case .transcript: "text.alignleft"
        case .zoom: "plus.magnifyingglass"; case .media: "photo.on.rectangle"; case .audio: "music.note"; case .canvas: "aspectratio"
        case .colour: "camera.filters"; case .claude: "sparkles"
        }
    }
}

@MainActor
final class ReelEditor: ObservableObject {
    let url: URL
    @Published var plan: EditPlan { didSet { if plan != oldValue { planChanged(from: oldValue) } } }
    @Published var size: ReelSize = .vertical {
        didSet {
            guard size != oldValue else { return }
            if toSave == [oldValue] { toSave = [size] }
            scheduleRebuild(after: 0)
        }
    }
    @Published var aspect: CGFloat = 9.0 / 16.0
    @Published var renderSize = CGSize(width: 1080, height: 1920)
    /// Which shapes "Export" writes, and how sharp.
    @Published var toSave: Set<ReelSize> = [.vertical]
    @Published var resolution = 1.0
    @Published var analysis: Analysis?
    @Published var status: String? = "Finding the pauses…"
    @Published var transcribing: Double?
    @Published var chat: [ChatLine] = []
    @Published var thinking = false
    @Published var exporting: (size: ReelSize, progress: Double)?
    @Published var saved: [URL] = []
    @Published var error: String?
    @Published var replaceOriginal = false
    @Published private(set) var timeline = EditTimeline(spans: [], plan: EditPlan(title: ""))
    @Published private(set) var cues: [Cue] = []
    /// The playhead, in seconds of the edited video.
    @Published var time: Double = 0
    @Published var playing = false
    @Published var selection: Selection = .none { didSet { if selection != .range { range = nil } } }
    /// A stretch of the edited video picked by dragging across the timeline.
    @Published var range: TimeSpan?
    @Published var tool: StudioTool = .edit
    let player = AVPlayer()
    private var renderer: ReelRenderer?
    private var rebuildTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var undo: [EditPlan] = []
    private var redo: [EditPlan] = []
    private var timeObserver: Any?
    private var statusWatch: NSKeyValueObservation?
    private var started = false
    private(set) var voiced: [TimeSpan] = []

    init(url: URL) {
        self.url = url
        plan = Analyzer.load(EditPlan.self, Analyzer.cacheURL(for: url, "plan")) ?? EditPlan(title: Namer.displayTitle(of: url))
        chat = Analyzer.load([ChatLine].self, Analyzer.cacheURL(for: url, "chat")) ?? []
        player.actionAtItemEnd = .pause
        // The playhead follows the player while it plays; whether it's playing comes straight from the player.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.player.timeControlStatus != .paused else { return }
                self.time = t.seconds
            }
        }
        statusWatch = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let on = p.timeControlStatus != .paused
            DispatchQueue.main.async {
                guard let self, self.playing != on else { return }
                self.playing = on
                if !on { self.time = self.player.currentTime().seconds }
            }
        }
    }

    var canUndo: Bool { !undo.isEmpty }
    var canRedo: Bool { !redo.isEmpty }
    var editedLength: Double { timeline.duration }
    var originalLength: Double { analysis?.duration ?? 0 }
    var spans: [TimeSpan] { analysis.map { Cutter.spans($0, plan) } ?? [] }
    var cutCount: Int { max(0, timeline.pieces.filter(\.afterCut).count - 1) }
    /// The words captions are made from: your corrections, or the transcript.
    var words: [Word] { plan.words ?? analysis?.words ?? [] }

    /// How many reel saves are running, so quitting can warn first.
    @MainActor static var saving = 0

    func start() {
        guard !started else { return }
        started = true
        Task {
            var a: Analysis
            if let cached = Analyzer.load(Analysis.self, Analyzer.cacheURL(for: url, "analysis")) {
                a = cached
            } else {
                do { a = try await Analyzer.levels(of: url) } catch {
                    self.error = "Couldn't read this recording: \(error.localizedDescription)"; status = nil; return
                }
                Analyzer.save(a, Analyzer.cacheURL(for: url, "analysis"))
            }
            analysis = a
            voiced = Cutter.voiced(a)
            status = nil
            audioTracks = max(1, (try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count) ?? 1)
            refreshTimeline()
            rebuild()
            refreshAudio()
            if a.words == nil || (a.engine != "whisper" && Whisper.ready) { await transcribe() }
        }
    }

    /// Leaving the editor: stop playing and keep the edit. (The clock stays wired up, in case it comes back.)
    func stop() {
        player.pause()
        saveTask?.cancel()
        savePlan()
    }

    // MARK: Captions

    @Published var whisperReady = Whisper.ready
    @Published var modelDownload: Double?

    /// Whisper when it's set up (accurate), otherwise Apple's on-device recognition.
    func transcribe() async {
        guard var a = analysis, transcribing == nil else { return }
        transcribing = 0
        let url = self.url
        let report: @Sendable (Double) -> Void = { p in Task { @MainActor in self.transcribing = p } }
        if Whisper.ready {
            do {
                a.words = try await Whisper.transcribe(url, voiced: Cutter.voiced(a), progress: report)
                a.engine = "whisper"
            } catch {
                log("whisper: \(error.localizedDescription)")
                self.error = "Whisper couldn't transcribe this one, so captions use Apple's recognition."
            }
        }
        if a.engine != "whisper" {
            let snapshot = a
            a.words = await Task.detached { await Analyzer.words(of: url, analysis: snapshot, progress: report) }.value
            a.engine = "apple"
        }
        analysis = a
        Analyzer.save(a, Analyzer.cacheURL(for: url, "analysis"))
        transcribing = nil
        refreshTimeline()
        rebuild()
    }

    func downloadModel() {
        guard modelDownload == nil else { return }
        modelDownload = 0
        Task {
            do {
                try await Whisper.downloadModel { p in Task { @MainActor in self.modelDownload = p } }
                whisperReady = Whisper.ready
                modelDownload = nil
                if whisperReady { await transcribe() }
            } catch {
                modelDownload = nil
                self.error = "Couldn't download the Whisper model: \(error.localizedDescription)"
            }
        }
    }

    func checkWhisper() {
        whisperReady = Whisper.ready
        if whisperReady, analysis?.engine != "whisper" { Task { await transcribe() } }
    }

    // MARK: Keeping the preview current

    private func planChanged(from old: EditPlan) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.savePlan()
        }
        if plan.audio.recipe != old.audio.recipe { refreshAudio() }
        if plan.changesTiming(from: old) {
            refreshTimeline()
            scheduleRebuild(after: 0.2)
        } else {
            if plan.words != old.words || plan.captionStyle.wordsPerCue != old.captionStyle.wordsPerCue { refreshCues() }
            renderer?.update(plan)
            redraw()
        }
    }

    private func refreshTimeline() {
        guard let a = analysis else { return }
        timeline = EditTimeline(spans: Cutter.spans(a, plan), plan: plan)
        refreshCues()
        if time > timeline.duration { time = timeline.duration }
    }

    private func refreshCues() {
        cues = Captions.cues(words, timeline: timeline, perCue: plan.captionStyle.wordsPerCue)
        fillerWords = words.filter { Self.fillers.contains(bare($0.text)) && timeline.output(at: ($0.start + $0.end) / 2) != nil }
        repeats = findRepeats()
    }

    /// Filler words and repeats still in the video, worked out when the edit or the words change.
    @Published private(set) var fillerWords: [Word] = []
    @Published private(set) var repeats: [TimeSpan] = []

    /// A word said twice in a row ("the the"), and a phrase that's said again straight after (a retake):
    /// the first go is the one to cut.
    private func findRepeats() -> [TimeSpan] {
        let ws = words.filter { !isCut($0) }
        guard ws.count > 1 else { return [] }
        var out: [TimeSpan] = []
        for i in 0..<(ws.count - 1) {
            let a = bare(ws[i].text), b = bare(ws[i + 1].text)
            if !a.isEmpty, a == b, ws[i + 1].start - ws[i].end < 0.8, a.count > 1 || a == "i" { out.append(TimeSpan(start: ws[i].start, end: ws[i + 1].start)) }
        }
        // Phrases split at pauses and full stops.
        var phrases: [Range<Int>] = []
        var s0 = 0
        for i in 1...ws.count {
            if i == ws.count || ws[i].start - ws[i - 1].end > 0.6 || ws[i - 1].text.last.map({ ".?!".contains($0) }) == true {
                phrases.append(s0..<i); s0 = i
            }
        }
        for k in 0..<max(0, phrases.count - 1) {
            let p = phrases[k], q = phrases[k + 1]
            let x = ws[p].map { bare($0.text) }, y = ws[q].map { bare($0.text) }
            guard x.count >= 3, ws[q.lowerBound].start - ws[p.upperBound - 1].end < 6 else { continue }
            let sameStart = y.count >= 3 && Array(x.prefix(3)) == Array(y.prefix(3))
            let overlap = Double(Set(x).intersection(Set(y)).count) / Double(max(1, Set(x).count))
            if sameStart || (overlap >= 0.75 && Double(x.count) <= Double(y.count) * 1.3) {
                out.append(TimeSpan(start: ws[p.lowerBound].start, end: ws[q.lowerBound].start))
            }
        }
        return Cutter.merge(out)
    }

    func removeRepeats() {
        let list = repeats
        guard !list.isEmpty else { return }
        change { p in for r in list { p.cut(r) } }
    }

    // MARK: The sound studio

    /// How far along the sound processing is, while it runs.
    @Published var audioWork: Double?
    @Published private(set) var audioTracks = 1
    @Published private(set) var echoDelay: Double?
    private var audioJob: Task<AudioResult, Error>?

    /// Starts processing the sound for the current settings, unless it's done already. The preview
    /// uses the original sound meanwhile and switches over when it's ready.
    func refreshAudio() {
        let r = plan.audio.recipe
        audioJob?.cancel()
        guard !r.isEmpty, analysis != nil else { audioWork = nil; return }
        if let res = AudioStudio.load(url, r) { echoDelay = res.echoDelay; audioWork = nil; return }
        audioWork = 0
        let url = self.url
        let job = Task.detached(priority: .userInitiated) {
            try await Task.sleep(for: .milliseconds(500))   // settle while sliders move
            return try await AudioStudio.process(url, r) { p in Task { @MainActor in if self.plan.audio.recipe == r { self.audioWork = p } } }
        }
        audioJob = job
        Task {
            do {
                let res = try await job.value
                guard plan.audio.recipe == r else { return }
                echoDelay = res.echoDelay
                audioWork = nil
                rebuild()
            } catch is CancellationError {
            } catch {
                guard plan.audio.recipe == r else { return }
                audioWork = nil
                self.error = "Couldn't process the sound: \(error.localizedDescription)"
            }
        }
    }

    private func scheduleRebuild(after seconds: Double) {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
            guard !Task.isCancelled else { return }
            self?.rebuild()
        }
    }

    func rebuild() {
        guard analysis != nil else { return }
        let plan = self.plan, size = self.size, url = self.url, timeline = self.timeline, words = self.words, voiced = self.voiced
        let levels = analysis?.levels ?? [], hop = analysis?.hop ?? 0.02
        let wasAt = time, playing = self.playing
        Task {
            do {
                // The preview draws at 720p so it keeps up; saving draws full size.
                let b = try await ReelBuilder.build(url: url, timeline: timeline, plan: plan, size: size, resolution: 2.0 / 3.0,
                                                    words: words, voiced: voiced, levels: levels, hop: hop)
                guard timeline == self.timeline, size == self.size else { return }  // a newer edit is on its way
                let item = AVPlayerItem(asset: b.composition)
                item.videoComposition = b.video
                item.audioMix = b.audioMix
                item.audioTimePitchAlgorithm = .spectral
                self.renderer = b.renderer
                b.renderer.update(self.plan)
                self.player.replaceCurrentItem(with: item)
                self.aspect = b.renderSize.width / b.renderSize.height
                self.renderSize = b.renderSize
                self.seek(min(wasAt, max(0, b.duration - 0.01)))
                if playing { self.player.play() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Shows the latest look on a paused frame (a playing video picks it up on its own).
    private var redrawPending = false
    private func redraw() {
        guard !playing, !redrawPending, let item = player.currentItem else { return }
        redrawPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
            guard let self else { return }
            self.redrawPending = false
            if let vc = item.videoComposition?.mutableCopy() as? AVVideoComposition { item.videoComposition = vc }
        }
    }

    // MARK: Playing

    func seek(_ t: Double) {
        let t = min(max(0, t), max(0, timeline.duration))
        time = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if player.timeControlStatus != .paused { player.pause(); return }
        if time >= timeline.duration - 0.05 { seek(0) }
        player.play()
    }

    func step(frames: Int) {
        player.pause()
        seek(time + Double(frames) / 30)
    }

    /// Jumps to the previous or next join between clips.
    func jump(_ direction: Int) {
        let joins = [0] + timeline.pieces.map(\.out.end)
        if direction < 0 { seek(joins.last { $0 < time - 0.05 } ?? 0) } else { seek(joins.first { $0 > time + 0.05 } ?? timeline.duration) }
    }

    // MARK: Changing the edit

    func change(_ f: (inout EditPlan) -> Void) {
        undo.append(plan)
        if undo.count > 200 { undo.removeFirst() }
        redo = []
        f(&plan)
    }

    /// Marks an undo step before a drag or slider changes the edit directly.
    func beginChange() { change { _ in } }

    func undoLast() {
        guard let p = undo.popLast() else { return }
        redo.append(plan)
        plan = p
    }

    func redoLast() {
        guard let p = redo.popLast() else { return }
        undo.append(plan)
        plan = p
    }

    private func savePlan() { Analyzer.save(plan, Analyzer.cacheURL(for: url, "plan")) }

    var selectedClip: (index: Int, clip: Clip)? {
        guard case .piece(let s) = selection, !timeline.clips.isEmpty else { return nil }
        // The clip that starts there, or holds that moment, or starts just after it (a trim can land in a pause).
        let i = timeline.clips.firstIndex { abs($0.src.start - s) < 0.02 }
            ?? timeline.clips.firstIndex { $0.src.start <= s && $0.src.end > s }
            ?? timeline.clips.firstIndex { $0.src.start > s && $0.src.start - s < 1.5 }
        guard let i else { return nil }
        return (i, timeline.clips[i])
    }

    func select(_ s: Selection) {
        selection = s
        switch s {
        case .text: tool = .text
        case .zoom: tool = .zoom
        case .image, .video, .blur: tool = .media
        case .music: tool = .audio
        case .piece, .range: if tool != .edit && tool != .audio { tool = .edit }
        case .none: break
        }
    }

    /// Splits the picked text or zoom at the playhead, or else the video.
    func split() {
        let s = timeline.source(at: time)
        switch selection {
        case .text(let id):
            guard let i = plan.texts.firstIndex(where: { $0.id == id }), s > plan.texts[i].start + 0.1, s < plan.texts[i].end - 0.1 else { break }
            change { p in
                var second = p.texts[i]
                second.id = UUID()
                second.start = s
                p.texts[i].end = s
                p.texts.insert(second, at: i + 1)
            }
            return
        case .zoom(let id):
            guard let i = plan.zooms.firstIndex(where: { $0.id == id }), s > plan.zooms[i].start + 0.1, s < plan.zooms[i].end - 0.1 else { break }
            change { p in
                var second = p.zooms[i]
                second.id = UUID()
                second.start = s
                p.zooms[i].end = s
                p.zooms.insert(second, at: i + 1)
            }
            return
        default: break
        }
        guard let i = timeline.index(at: time) else { return }
        let piece = timeline.pieces[i]
        guard s > piece.src.start + 0.08, s < piece.src.end - 0.08 else { return }
        change { $0.splits.append(s) }
        selection = .piece(s)
    }

    func deleteSelection() {
        switch selection {
        case .piece:
            guard let (_, clip) = selectedClip else { return }
            change { $0.cut(clip.src) }
            selection = .none
        case .text(let id): change { $0.texts.removeAll { $0.id == id } }; selection = .none
        case .zoom(let id): change { $0.zooms.removeAll { $0.id == id } }; selection = .none
        case .image(let id): change { $0.images.removeAll { $0.id == id } }; selection = .none
        case .video(let id): change { $0.videos.removeAll { $0.id == id } }; selection = .none
        case .blur(let id): change { $0.blurs.removeAll { $0.id == id } }; selection = .none
        case .music: change { $0.music = nil }; selection = .none
        case .range:
            guard let r = range else { return }
            let parts = timeline.sourceRanges(from: r.start, to: r.end)
            change { p in for part in parts { p.cut(part) } }
            seek(r.start)
            selection = .none
        case .none: break
        }
    }

    // MARK: A dragged-out stretch

    func selectRange(_ a: Double, _ b: Double) {
        let lo = max(0, min(a, b)), hi = min(timeline.duration, max(a, b))
        guard hi - lo > 0.03 else { return }
        range = TimeSpan(start: lo, end: hi)
        if selection != .range { selection = .range; if tool != .edit && tool != .audio { tool = .edit } }
    }

    /// Keeps only the picked stretch: everything before and after it is cut.
    func keepOnlyRange() {
        guard let r = range else { return }
        let parts = timeline.sourceRanges(from: 0, to: r.start) + timeline.sourceRanges(from: r.end, to: timeline.duration)
        change { p in for part in parts { p.cut(part) } }
        selection = .none
        seek(0)
    }

    /// Makes the picked stretch its own clip, so it can be moved on with its own speed and volume.
    func splitRange() {
        guard let r = range else { return }
        let a = timeline.source(at: r.start), b = timeline.source(at: r.end, preferEnd: true)
        change { $0.splits += [a, b] }
        selection = .piece(a)
    }

    /// Speed or volume for the picked stretch (it becomes its own clip).
    func setRange(speed: Double? = nil, volume: Double? = nil, mic: Double? = nil, sys: Double? = nil) {
        guard let r = range else { return }
        let src = TimeSpan(start: timeline.source(at: r.start), end: timeline.source(at: r.end, preferEnd: true))
        let clip = Clip(pieces: 0..<0, src: src, out: r, speed: 1, volume: 1)
        setClip(speed: speed, volume: volume, mic: mic, sys: sys, for: clip)
        // Where the stretch now lands, so it stays picked.
        if let a = timeline.output(at: src.start), let b = timeline.output(at: src.end) { range = TimeSpan(start: a, end: b) }
    }

    func zoomOnRange() {
        guard let r = range else { return }
        let z = ZoomItem(start: timeline.source(at: r.start), end: timeline.source(at: r.end, preferEnd: true))
        change { $0.zooms.append(z) }
        select(.zoom(z.id))
    }

    func textOnRange() {
        guard let r = range else { return }
        var t = Self.textPresets[0].item
        t.id = UUID()
        t.start = timeline.source(at: r.start)
        t.end = timeline.source(at: r.end, preferEnd: true)
        change { $0.texts.append(t) }
        select(.text(t.id))
    }

    func duplicateSelection() {
        switch selection {
        case .text(let id):
            guard let t = plan.texts.first(where: { $0.id == id }) else { return }
            var c = t
            c.id = UUID()
            c.y = min(0.92, t.y + 0.08)
            change { $0.texts.append(c) }
            selection = .text(c.id)
        case .zoom(let id):
            guard let z = plan.zooms.first(where: { $0.id == id }) else { return }
            var c = z
            c.id = UUID()
            let len = z.end - z.start
            c.start = z.end + 0.5
            c.end = c.start + len
            change { $0.zooms.append(c) }
            selection = .zoom(c.id)
        default: break
        }
    }

    /// Speed, volume or the mix of the two sound tracks for one clip, on top of the whole video's.
    func setClip(speed: Double? = nil, volume: Double? = nil, mic: Double? = nil, sys: Double? = nil, for clip: Clip) {
        func set(_ list: [Ranged], _ v: Double) -> [Ranged] {
            var out: [Ranged] = []
            for r in list {
                for part in Cutter.subtract(clip.src, from: TimeSpan(start: r.start, end: r.end)) where part.length > 0.01 {
                    out.append(Ranged(start: part.start, end: part.end, value: r.value))
                }
            }
            if abs(v - 1) > 0.001 { out.append(Ranged(start: clip.src.start, end: clip.src.end, value: v)) }
            return out
        }
        if let s = speed { plan.clipSpeeds = set(plan.clipSpeeds, s) }
        if let v = volume { plan.clipVolumes = set(plan.clipVolumes, v) }
        if let v = mic { plan.clipMic = set(plan.clipMic, v) }
        if let v = sys { plan.clipSys = set(plan.clipSys, v) }
    }

    func clipSpeed(_ c: Clip) -> Double { c.speed / max(0.01, plan.speed) }

    /// Drags one end of a clip to a new moment of the original: shorter cuts, longer brings back.
    func trim(_ index: Int, start: Bool, to s: Double) {
        guard index < timeline.clips.count, let a = analysis else { return }
        let clips = timeline.clips, p = clips[index]
        if start {
            let lo = index > 0 ? clips[index - 1].src.end : 0
            let v = min(max(s, lo), p.src.end - 0.1)
            if v > p.src.start { plan.cut(TimeSpan(start: p.src.start, end: v)) } else { plan.restore(TimeSpan(start: v, end: p.src.start)) }
            if selection == .piece(p.src.start) { selection = .piece(v) }
        } else {
            let hi = index + 1 < clips.count ? clips[index + 1].src.start : a.duration
            let v = max(min(s, hi), p.src.start + 0.1)
            if v < p.src.end { plan.cut(TimeSpan(start: v, end: p.src.end)) } else { plan.restore(TimeSpan(start: p.src.end, end: v)) }
        }
    }

    /// Moves or stretches a text, zoom or picture to a stretch of the edited video.
    func setSpan(_ s: Selection, from a: Double, to b: Double) {
        let lo = max(0, min(a, b)), hi = min(timeline.duration, max(a, b))
        guard hi - lo > 0.05 else { return }
        let start = timeline.source(at: lo), end = timeline.source(at: hi, preferEnd: true)
        switch s {
        case .text(let id): if let i = plan.texts.firstIndex(where: { $0.id == id }) { plan.texts[i].start = start; plan.texts[i].end = end }
        case .zoom(let id): if let i = plan.zooms.firstIndex(where: { $0.id == id }) { plan.zooms[i].start = start; plan.zooms[i].end = end }
        case .image(let id): if let i = plan.images.firstIndex(where: { $0.id == id }) { plan.images[i].start = start; plan.images[i].end = end }
        case .video(let id): if let i = plan.videos.firstIndex(where: { $0.id == id }) { plan.videos[i].start = start; plan.videos[i].end = end }
        case .blur(let id): if let i = plan.blurs.firstIndex(where: { $0.id == id }) { plan.blurs[i].start = start; plan.blurs[i].end = end }
        default: break
        }
    }

    // MARK: Adding things

    static let textPresets: [(name: String, item: TextItem)] = [
        ("Title", TextItem(text: "Your title", start: 0, end: 0, y: 0.2, size: 0.1, weight: "heavy", style: "shadow", animation: "pop")),
        ("Subtitle", TextItem(text: "A short line", start: 0, end: 0, y: 0.3, size: 0.06, weight: "bold", style: "shadow", animation: "slide")),
        ("Label", TextItem(text: "Label", start: 0, end: 0, y: 0.82, size: 0.05, weight: "bold", color: "111111", style: "box", boxColor: "FFFFFF", animation: "fade")),
        ("Caption box", TextItem(text: "Something to note", start: 0, end: 0, y: 0.72, size: 0.045, weight: "medium", style: "box", animation: "fade")),
        ("Typewriter", TextItem(text: "Typing it out…", start: 0, end: 0, y: 0.5, size: 0.055, font: "mono", weight: "bold", style: "shadow", animation: "typewriter")),
        ("Big number", TextItem(text: "10×", start: 0, end: 0, y: 0.45, size: 0.2, font: "rounded", weight: "heavy", color: "FFD60A", style: "outline", animation: "pop")),
    ]

    func addText(_ preset: TextItem) {
        var t = preset
        t.id = UUID()
        t.start = timeline.source(at: time)
        t.end = timeline.source(at: min(timeline.duration, time + 3), preferEnd: true)
        if t.end - t.start < 0.3 { t.end = t.start + 3 }
        change { $0.texts.append(t) }
        select(.text(t.id))
    }

    func addZoom() {
        var z = ZoomItem(start: timeline.source(at: time), end: timeline.source(at: min(timeline.duration, time + 2.5), preferEnd: true))
        if z.end - z.start < 0.5 { z.end = z.start + 2.5 }
        change { $0.zooms.append(z) }
        select(.zoom(z.id))
    }

    /// Keeps a copy of a picture or song with Bubble's edits, so the edit still works if the original moves.
    private func keep(_ file: URL) -> URL? {
        let dir = Analyzer.cacheURL(for: url, "x").deletingLastPathComponent().appendingPathComponent("Assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(file.lastPathComponent)")
        do { try FileManager.default.copyItem(at: file, to: dest); return dest } catch {
            self.error = "Couldn't add \(file.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    func addImage(_ file: URL) {
        guard let kept = keep(file), let a = analysis else { return }
        let item = ImageItem(file: kept.path, name: file.deletingPathExtension().lastPathComponent, start: 0, end: a.duration)
        change { $0.images.append(item) }
        select(.image(item.id))
    }

    /// A blur box from the playhead for five seconds (or over the picked stretch).
    func addBlur() {
        var b = BlurItem(start: timeline.source(at: range?.start ?? time),
                         end: timeline.source(at: min(timeline.duration, range?.end ?? time + 5), preferEnd: true))
        if b.end - b.start < 0.5 { b.end = b.start + 5 }
        change { $0.blurs.append(b) }
        select(.blur(b.id))
    }

    /// Another video on top, from the playhead, as long as it lasts.
    func addVideo(_ file: URL) {
        guard let kept = keep(file) else { return }
        let at = time
        Task {
            let asset = AVURLAsset(url: kept)
            let len = (try? await asset.load(.duration).seconds) ?? 5
            var aspect = 16.0 / 9.0
            if let v = try? await asset.loadTracks(withMediaType: .video).first, let n = try? await v.load(.naturalSize), let t = try? await v.load(.preferredTransform) {
                let r = CGRect(origin: .zero, size: n).applying(t)
                if r.height > 0 { aspect = abs(r.width / r.height) }
            }
            let start = timeline.source(at: at)
            let end = timeline.source(at: min(timeline.duration, at + max(0.5, len)), preferEnd: true)
            var item = VideoItem(file: kept.path, name: file.deletingPathExtension().lastPathComponent, start: start, end: max(end, start + 0.5))
            item.aspect = aspect
            if size == .vertical { item.width = 0.62; item.y = 0.26; item.x = 0.5 }
            change { $0.videos.append(item) }
            select(.video(item.id))
        }
    }

    /// Files dropped on the editor: pictures, videos and songs each go where they belong.
    func add(files: [URL]) {
        for f in files {
            guard let type = UTType(filenameExtension: f.pathExtension) else { continue }
            if type.conforms(to: .image) { addImage(f) } else if type.conforms(to: .audio) { setMusic(f) } else if type.conforms(to: .movie) || type.conforms(to: .video) { addVideo(f) }
        }
    }

    func setMusic(_ file: URL) {
        guard let kept = keep(file) else { return }
        change { $0.music = MusicTrack(file: kept.path, name: file.deletingPathExtension().lastPathComponent) }
        select(.music)
    }

    // MARK: Words

    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "ahh", "hmm", "mm", "mhm"]

    private func bare(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }


    func removeFillers() {
        let list = fillerWords
        guard !list.isEmpty else { return }
        change { p in for w in list { p.cut(TimeSpan(start: max(0, w.start - 0.03), end: w.end + 0.03)) } }
    }

    func isCut(_ w: Word) -> Bool { timeline.output(at: (w.start + w.end) / 2) == nil }

    /// Cuts the words from the video (selecting them in the transcript and pressing Delete).
    func cutWords(_ r: Range<Int>) {
        let ws = words
        guard !r.isEmpty, r.lowerBound >= 0, r.upperBound <= ws.count else { return }
        let start = ws[r.lowerBound].start, end = ws[r.upperBound - 1].end
        // Take the gap up to the next word too, so the cut doesn't leave a pause.
        let next = r.upperBound < ws.count ? ws[r.upperBound].start : end
        change { $0.cut(TimeSpan(start: start, end: min(next, end + 0.25))) }
    }

    func restoreWords(_ r: Range<Int>) {
        let ws = words
        guard !r.isEmpty, r.upperBound <= ws.count else { return }
        change { $0.restore(TimeSpan(start: ws[r.lowerBound].start - 0.05, end: ws[r.upperBound - 1].end + 0.05)) }
    }

    /// The transcript as you've typed it: words you kept keep their timing, new ones share the time
    /// of the words they replaced, and the captions follow straight away.
    func applyTranscript(_ tokens: [String]) {
        let old = words
        guard !old.isEmpty, tokens != old.map(\.text) else { return }
        change { $0.words = Self.realign(old, tokens) }
    }

    static func realign(_ old: [Word], _ new: [String]) -> [Word] {
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in new.difference(from: old.map(\.text)) {
            switch c {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        // Pair up the words that stayed, in order.
        var kept: [Int: Int] = [:]
        var oi = 0
        for ni in 0..<new.count where !inserted.contains(ni) {
            while removed.contains(oi) { oi += 1 }
            if oi < old.count { kept[ni] = oi }
            oi += 1
        }
        var out: [Word] = []
        var ni = 0
        while ni < new.count {
            if let o = kept[ni] { out.append(Word(text: new[ni], start: old[o].start, end: old[o].end)); ni += 1; continue }
            var nj = ni
            while nj < new.count && kept[nj] == nil { nj += 1 }
            let prev = ni > 0 ? kept[ni - 1] : nil, next = nj < new.count ? kept[nj] : nil
            let lo = (prev ?? -1) + 1, hi = next ?? old.count
            var start: Double, end: Double
            if lo < hi {
                start = old[lo].start; end = old[hi - 1].end
            } else {
                start = prev.map { old[$0].end } ?? next.map { max(0, old[$0].start - 0.3) } ?? 0
                end = next.map { old[$0].start } ?? start + 0.3
                if end - start < 0.05 * Double(nj - ni) { end = start + 0.05 * Double(nj - ni) }
            }
            let total = Double(new[ni..<nj].reduce(0) { $0 + $1.count + 1 })
            var at = start
            for k in ni..<nj {
                let len = (end - start) * Double(new[k].count + 1) / max(1, total)
                out.append(Word(text: new[k], start: at, end: at + len))
                at += len
            }
            ni = nj
        }
        return out
    }

    /// Rewrites a caption. The new words share the old ones' time, in proportion to their length.
    func editCue(_ cue: Cue, text: String) {
        var ws = words
        guard cue.range.upperBound <= ws.count, !cue.range.isEmpty else { return }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let start = ws[cue.range.lowerBound].start, end = ws[cue.range.upperBound - 1].end
        let total = max(1, tokens.reduce(0) { $0 + $1.count + 1 })
        var at = start, new: [Word] = []
        for t in tokens {
            let len = (end - start) * Double(t.count + 1) / Double(total)
            new.append(Word(text: t, start: at, end: at + len))
            at += len
        }
        guard new.map(\.text) != ws[cue.range].map(\.text) else { return }
        ws.replaceSubrange(cue.range, with: new)
        change { $0.words = ws }
    }

    // MARK: Chat

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !thinking, let a = analysis else { return }
        chat.append(ChatLine(fromUser: true, text: t))
        thinking = true
        Task {
            do {
                let (newPlan, reply) = try await ReelAssistant.ask(t, history: Array(chat.dropLast().suffix(12)), plan: plan, analysis: a,
                                                                    spans: spans, editedLength: editedLength)
                if newPlan != plan { change { $0 = newPlan } }
                chat.append(ChatLine(fromUser: false, text: reply))
            } catch {
                chat.append(ChatLine(fromUser: false, text: error.localizedDescription))
            }
            thinking = false
            Analyzer.save(chat, Analyzer.cacheURL(for: url, "chat"))
        }
    }

    func clearChat() {
        chat = []
        Analyzer.save(chat, Analyzer.cacheURL(for: url, "chat"))
    }

    // MARK: Saving

    /// Writes the chosen shapes to Bubble Recordings/Reels, then (if asked) moves the original to the Bin.
    func save() {
        guard exporting == nil, analysis != nil else { return }
        player.pause()
        saved = []
        error = nil
        let plan = self.plan, url = self.url, timeline = self.timeline, words = self.words, voiced = self.voiced, resolution = self.resolution
        let levels = analysis?.levels ?? [], hop = analysis?.hop ?? 0.02
        let safe = plan.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Full speed even while you work in another app (macOS slows background apps otherwise).
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Saving reels")
        Self.saving += 1
        Task {
            defer { ProcessInfo.processInfo.endActivity(activity); Self.saving -= 1 }
            let sizes = ReelSize.allCases.filter { toSave.contains($0) }
            for size in sizes {
                exporting = (size, 0)
                let out = Settings.reelsFolder.appendingPathComponent("\(safe.isEmpty ? "Reel" : safe) · \(size.fileTag).mp4")
                do {
                    let b = try await ReelBuilder.build(url: url, timeline: timeline, plan: plan, size: size, resolution: resolution, words: words, voiced: voiced, levels: levels, hop: hop)
                    try await ReelBuilder.export(b, to: out) { p in Task { @MainActor in self.exporting = (size, p) } }
                    saved.append(out)
                    log("reel saved: \(out.lastPathComponent)")
                } catch {
                    self.error = "Couldn't save the \(size.ratio) video: \(error.localizedDescription)"
                    log("reel export failed: \(error)")
                    break
                }
            }
            exporting = nil
            if saved.count == sizes.count {
                Sounds.stop()
                if replaceOriginal { NSWorkspace.shared.recycle([url]) { _, _ in } }
            }
        }
    }
}

// MARK: - Claude

enum ReelAssistant {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let tool: [String: Any] = [
        "name": "update_edit",
        "description": "Apply the edit. Leave out any field that should stay as it is.",
        "input_schema": [
            "type": "object",
            "properties": [
                "reply": ["type": "string", "description": "One or two short sentences to the user saying what you changed, in plain words."],
                "max_pause": ["type": "number", "description": "Seconds of silence left between phrases (0.1 very tight, 0.25 sharp, 0.5 relaxed). 0 keeps every pause uncut."],
                "removed": ["type": "array", "description": "The full list of parts of the ORIGINAL video to cut, in seconds. Include the existing ones you want to keep cut.",
                            "items": ["type": "object", "properties": ["start": ["type": "number"], "end": ["type": "number"]], "required": ["start", "end"]]],
                "kept": ["type": "array", "description": "The full list of parts of the ORIGINAL video to keep even if silent (e.g. a demo without talking).",
                         "items": ["type": "object", "properties": ["start": ["type": "number"], "end": ["type": "number"]], "required": ["start", "end"]]],
                "speed": ["type": "number", "description": "Playback speed, 0.75 to 2."],
                "captions": ["type": "boolean"],
                "caption_position": ["type": "string", "enum": ["top", "middle", "bottom"]],
                "zoom": ["type": "number", "description": "1 shows the whole recording; up to 4 crops in towards the focus point."],
                "focus_x": ["type": "number", "description": "Where to crop towards, 0 left to 1 right."],
                "focus_y": ["type": "number", "description": "Where to crop towards, 0 top to 1 bottom."],
                "title": ["type": "string", "description": "File name for the reels."],
                "texts": ["type": "array", "description": "The full list of text overlays (titles, labels, callouts). Include existing ones you want to keep. Times are seconds in the ORIGINAL video.",
                          "items": ["type": "object", "properties": [
                            "text": ["type": "string"], "start": ["type": "number"], "end": ["type": "number"],
                            "x": ["type": "number", "description": "Centre, 0 left to 1 right. Default 0.5."],
                            "y": ["type": "number", "description": "Centre, 0 top to 1 bottom. Titles about 0.2, labels about 0.8."],
                            "size": ["type": "number", "description": "Height as a share of the frame's short side: 0.1 title, 0.06 subtitle, 0.045 label."],
                            "style": ["type": "string", "enum": ["plain", "shadow", "outline", "box"]],
                            "animation": ["type": "string", "enum": ["none", "fade", "pop", "slide", "typewriter"]],
                            "color": ["type": "string", "description": "Hex like FFFFFF."],
                          ] as [String: Any], "required": ["text", "start", "end"]] as [String: Any]] as [String: Any],
                "zooms": ["type": "array", "description": "The full list of zoom moments: the view pushes in towards a point and eases back out. Times are seconds in the ORIGINAL video.",
                          "items": ["type": "object", "properties": [
                            "start": ["type": "number"], "end": ["type": "number"],
                            "scale": ["type": "number", "description": "1.25 gentle to 3 close. Default 1.8."],
                            "x": ["type": "number", "description": "Point to zoom towards, 0 left to 1 right."],
                            "y": ["type": "number", "description": "0 top to 1 bottom."],
                          ] as [String: Any], "required": ["start", "end"]] as [String: Any]] as [String: Any],
                "caption_style": ["type": "string", "enum": ["classic", "karaoke", "highlight", "box", "minimal"]],
                "layout": ["type": "string", "enum": ["fit", "fill", "framed"], "description": "fit shows the whole recording on a background, fill crops to fill, framed floats it with rounded corners."],
                "background": ["type": "string", "enum": ["blur", "color", "gradient"]],
            ],
            "required": ["reply"],
        ] as [String: Any],
    ]

    static func ask(_ message: String, history: [ChatLine], plan: EditPlan, analysis a: Analysis,
                    spans: [TimeSpan], editedLength: Double) async throws -> (EditPlan, String) {
        let system = """
        You edit screen recordings into short social media reels inside Bubble, a Mac app. The user tells you what \
        they want; you change the edit with the update_edit tool. Bubble already cuts silences automatically using \
        max_pause, lays the recording out as Original, 1:1, 9:16 and 16:9 over a blurred background, and adds captions. You can \
        also add text overlays and zoom moments, and change the caption style and layout. Times are always seconds in the \
        ORIGINAL recording. Use the transcript to find the parts the user means. To shorten \
        a video, cut repeated takes, false starts, tangents and dead air, and keep the core message. Never invent \
        content. If the request can't be done with these settings, say so in the reply and change nothing.
        """
        var transcript = ""
        if let words = a.words, !words.isEmpty {
            var line = "", lineStart = words[0].start
            for w in words {
                if line.isEmpty { lineStart = w.start }
                line += (line.isEmpty ? "" : " ") + w.text
                if line.count > 90 || w.text.last.map({ ".!?".contains($0) }) == true {
                    transcript += String(format: "[%.1f] %@\n", lineStart, line); line = ""
                }
            }
            if !line.isEmpty { transcript += String(format: "[%.1f] %@\n", lineStart, line) }
        } else {
            transcript = "(Not transcribed yet, or no speech.)"
        }
        let current: [String: Any] = [
            "max_pause": plan.maxPause ?? 0, "speed": plan.speed, "captions": plan.captions,
            "caption_position": plan.captionPosition, "zoom": plan.zoom, "focus_x": plan.focusX, "focus_y": plan.focusY,
            "title": plan.title, "removed": plan.removed.map { ["start": $0.start, "end": $0.end] },
            "kept": plan.kept.map { ["start": $0.start, "end": $0.end] },
            "texts": plan.texts.map { ["text": $0.text, "start": $0.start, "end": $0.end, "x": $0.x, "y": $0.y, "size": $0.size, "style": $0.style,
                                       "animation": $0.animation, "color": $0.color] as [String: Any] },
            "zooms": plan.zooms.map { ["start": $0.start, "end": $0.end, "scale": $0.scale, "x": $0.x, "y": $0.y] },
            "caption_style": plan.captionStyle.preset, "layout": plan.canvas.layout, "background": plan.canvas.background,
        ]
        let currentJSON = (try? JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let earlier = history.map { ($0.fromUser ? "User: " : "You: ") + $0.text }.joined(separator: "\n")
        let user = """
        <video>
        Original length: \(String(format: "%.1f", a.duration)) s. Current edit: \(String(format: "%.1f", editedLength)) s in \(spans.count) pieces.
        Current settings: \(currentJSON)
        </video>
        <transcript>
        \(transcript)</transcript>
        \(earlier.isEmpty ? "" : "<earlier_chat>\n\(earlier)\n</earlier_chat>\n")
        User's request: \(message)
        """
        let input = try await answer(system: system, user: user)
        return (apply(input, to: plan, duration: a.duration), input["reply"] as? String ?? "Done.")
    }

    /// Uses whichever Claude you've set up: your Claude subscription through Claude Code (no key needed),
    /// or your own API key. If one fails and the other is there, it tries the other.
    private static func answer(system: String, user: String) async throws -> [String: Any] {
        let codeFirst = Settings.assistantBrain == .claudeCode
        let bin = ClaudeCodeSession.binary
        let key = Keychain.apiKey.flatMap { $0.isEmpty ? nil : $0 }
        if codeFirst, let bin {
            do { return try await viaClaudeCode(bin, system: system, user: user) }
            catch { guard let key else { throw error }; log("reel chat: Claude Code failed (\(error.localizedDescription)), using the API key") ; return try await viaAPI(key, system: system, user: user) }
        }
        if let key {
            do { return try await viaAPI(key, system: system, user: user) }
            catch { guard let bin else { throw error }; return try await viaClaudeCode(bin, system: system, user: user) }
        }
        if let bin { return try await viaClaudeCode(bin, system: system, user: user) }
        if Keychain.hasKey {
            throw Failure(message: "Your saved API key couldn't be read (macOS asks again after Bubble updates). Paste it again below, or sign in to Claude Code.")
        }
        throw Failure(message: "Sign in to Claude Code, or add an Anthropic API key below, to chat.")
    }

    /// Claude Code, kept lean: only this prompt and the edit's shape, with no tools, connectors, skills or
    /// memory loaded, so a request costs a couple of thousand tokens of your plan, not hundreds of thousands.
    private static func viaClaudeCode(_ bin: URL, system: String, user: String) async throws -> [String: Any] {
        let schema = tool["input_schema"] ?? [:]
        let schemaJSON = (try? JSONSerialization.data(withJSONObject: schema)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-reels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = bin
        p.arguments = ["-p", "--output-format", "json", "--model", Settings.assistantModel.alias, "--no-session-persistence",
                       "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--setting-sources", "",
                       "--system-prompt", system, "--json-schema", schemaJSON]
        p.currentDirectoryURL = dir  // an empty folder: no project files or notes get pulled in
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [bin.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        p.environment = env
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice

        let data: Data = try await withCheckedThrowingContinuation { done in
            DispatchQueue.global().async {
                do { try p.run() } catch { done.resume(throwing: Failure(message: "Couldn't start Claude Code: \(error.localizedDescription)")); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 150, execute: killer)
                input.fileHandleForWriting.write(Data(user.utf8))
                try? input.fileHandleForWriting.close()
                let out = output.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                done.resume(returning: out)
            }
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let u = json["usage"] as? [String: Any] {
            let total = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"].compactMap { (u[$0] as? NSNumber)?.intValue }.reduce(0, +)
            log("reel chat: Claude Code, \(total) tokens")
        }
        if let s = json["structured_output"] as? [String: Any], json["is_error"] as? Bool != true { return s }
        let said = (json["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        log("reel chat: Claude Code didn't return an edit (\(json["subtype"] as? String ?? "no output"))")
        let lower = said.lowercased()
        if lower.contains("limit") { throw Failure(message: "You've reached your Claude usage limit for now. It resets on its own; an API key in Settings keeps the editor going meanwhile.") }
        if lower.contains("log in") || lower.contains("login") || lower.contains("auth") {
            throw Failure(message: "Claude Code isn't signed in. In Terminal run claude, then /login.")
        }
        if data.isEmpty { throw Failure(message: "Claude Code didn't answer. Check it's signed in (claude, then /login in Terminal).") }
        throw Failure(message: said.isEmpty ? "Claude didn't return an edit. Try rephrasing." : "Claude couldn't answer: \(said.prefix(160))")
    }

    private static func viaAPI(_ key: String, system: String, user: String) async throws -> [String: Any] {
        let body: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 8000,
            "output_config": ["effort": "medium"],
            "fallbacks": "default",
            "system": system,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "update_edit"],
            "messages": [["role": "user", "content": user]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            log("reel chat: \(msg)")
            throw Failure(message: "Claude couldn't answer: \(msg)")
        }
        if json["stop_reason"] as? String == "refusal" { throw Failure(message: "Claude declined that request.") }
        guard let input = (json["content"] as? [[String: Any]])?.first(where: { $0["type"] as? String == "tool_use" })?["input"] as? [String: Any] else {
            throw Failure(message: "Claude didn't return an edit. Try rephrasing.")
        }
        return input
    }

    private static func apply(_ i: [String: Any], to plan: EditPlan, duration: Double) -> EditPlan {
        var p = plan
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
        func spans(_ v: Any?) -> [TimeSpan]? {
            (v as? [[String: Any]])?.compactMap { d in
                guard let s = (d["start"] as? NSNumber)?.doubleValue, let e = (d["end"] as? NSNumber)?.doubleValue, e > s else { return nil }
                return TimeSpan(start: clamp(s, 0, duration), end: clamp(e, 0, duration))
            }
        }
        if let v = i["max_pause"] as? NSNumber { p.maxPause = v.doubleValue <= 0 ? 0 : clamp(v.doubleValue, 0.05, 2) }
        if let r = spans(i["removed"]) { p.removed = r }
        if let k = spans(i["kept"]) { p.kept = k }
        if let v = i["speed"] as? NSNumber { p.speed = clamp(v.doubleValue, 0.75, 2) }
        if let v = i["captions"] as? Bool { p.captions = v }
        if let v = i["caption_position"] as? String, ["top", "middle", "bottom"].contains(v) { p.captionPosition = v }
        if let v = i["zoom"] as? NSNumber { p.zoom = clamp(v.doubleValue, 1, 4) }
        if let v = i["focus_x"] as? NSNumber { p.focusX = clamp(v.doubleValue, 0, 1) }
        if let v = i["focus_y"] as? NSNumber { p.focusY = clamp(v.doubleValue, 0, 1) }
        if let v = i["title"] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty { p.title = v }
        func num(_ d: [String: Any], _ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        if let list = i["texts"] as? [[String: Any]] {
            p.texts = list.enumerated().compactMap { n, d in
                guard let text = d["text"] as? String, let s = num(d, "start"), let e = num(d, "end"), e > s else { return nil }
                // Keep the look of a text Claude only moved or reworded.
                var t = n < plan.texts.count ? plan.texts[n] : TextItem(text: text, start: s, end: e)
                t.text = text; t.start = clamp(s, 0, duration); t.end = clamp(e, 0, duration)
                if let v = num(d, "x") { t.x = clamp(v, 0, 1) }
                if let v = num(d, "y") { t.y = clamp(v, 0, 1) }
                if let v = num(d, "size") { t.size = clamp(v, 0.02, 0.3) }
                if let v = d["style"] as? String, ["plain", "shadow", "outline", "box"].contains(v) { t.style = v }
                if let v = d["animation"] as? String, ["none", "fade", "pop", "slide", "typewriter"].contains(v) { t.animation = v }
                if let v = d["color"] as? String, v.count == 6 || v.count == 7 { t.color = v.replacingOccurrences(of: "#", with: "") }
                return t
            }
        }
        if let list = i["zooms"] as? [[String: Any]] {
            p.zooms = list.enumerated().compactMap { n, d in
                guard let s = num(d, "start"), let e = num(d, "end"), e > s else { return nil }
                var z = n < plan.zooms.count ? plan.zooms[n] : ZoomItem(start: s, end: e)
                z.start = clamp(s, 0, duration); z.end = clamp(e, 0, duration)
                if let v = num(d, "scale") { z.scale = clamp(v, 1.1, 4) }
                if let v = num(d, "x") { z.x = clamp(v, 0, 1) }
                if let v = num(d, "y") { z.y = clamp(v, 0, 1) }
                return z
            }
        }
        if let v = i["caption_style"] as? String, Captions.presets.contains(where: { $0.0 == v }) { p.captionStyle.preset = v }
        if let v = i["layout"] as? String, ["fit", "fill", "framed"].contains(v) { p.canvas.layout = v }
        if let v = i["background"] as? String, ["blur", "color", "gradient"].contains(v) { p.canvas.background = v }
        return p
    }
}

// MARK: - The editor page

struct EditorPage: View {
    let url: URL
    let onClose: () -> Void
    @StateObject private var ed: ReelEditor
    @State private var keys: Any?
    @State private var showExport = false
    @State private var showAdd = false
    @State private var dropping = false
    @AppStorage("studioTimelineHeight") private var timelineHeight = 236.0
    @AppStorage("studioTheme") private var theme = "auto"
    @Environment(\.colorScheme) private var macScheme
    @Namespace private var railPill
    @Namespace private var shapePill
    /// The open editor, for test runs.
    static weak var lastEditor: ReelEditor?

    init(url: URL, onClose: @escaping () -> Void) {
        self.url = url
        self.onClose = onClose
        _ed = StateObject(wrappedValue: ReelEditor(url: url))
    }

    private var dark: Bool { theme == "dark" || (theme == "auto" && macScheme == .dark) }

    var body: some View {
        SC.dark = dark
        // Changing the look redraws everything; the editor itself (and the keys) carry on.
        return content.id(dark)
            .onAppear {
                ed.start(); installKeys(); Self.lastEditor = ed
                // Don't start with the title box holding the keyboard, so Space plays straight away.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
            .onDisappear { ed.stop(); if let k = keys { NSEvent.removeMonitor(k); keys = nil } }
    }

    private var content: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                rail
                StudioPanel(ed: ed)
                    .frame(width: 318)
                    .background(SC.panel)
                    .overlay(alignment: .trailing) { Rectangle().fill(SC.line).frame(width: 1) }
                    .animation(.spring(response: 0.38, dampingFraction: 0.86), value: ed.tool)
                stage
            }
            timelineDivider
            StudioTimeline(ed: ed)
                .frame(height: max(timelineHeight, StudioTimeline.height(for: ed)))
        }
        .background(SC.bg)
        .environment(\.colorScheme, dark ? .dark : .light)
        .tint(SC.accent)
        .overlay { if dropping { dropZone } }
        .onDrop(of: [.fileURL], isTargeted: $dropping.animation(SC.spring)) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { u, _ in
                    if let u { DispatchQueue.main.async { ed.add(files: [u]) } }
                }
            }
            return true
        }
    }

    private var dropZone: some View {
        ZStack {
            Color.black.opacity(0.45)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(SC.gradient, style: StrokeStyle(lineWidth: 2.5, dash: [10, 8]))
                .padding(24)
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 38, weight: .semibold)).foregroundStyle(SC.gradient)
                Text("Drop to add").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(SC.text)
                Text("Videos go on top, pictures as overlays, songs as music.").font(.system(size: 13)).foregroundStyle(SC.dim)
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold)).foregroundStyle(SC.text)
                    .frame(width: 30, height: 30).background(Circle().fill(SC.wash(0.07)))
                    .overlay(Circle().strokeBorder(SC.line))
            }
            .buttonStyle(Springy()).help("Back to recordings")
            VStack(alignment: .leading, spacing: 1) {
                TextField("Title", text: Binding(get: { ed.plan.title }, set: { v in ed.plan.title = v }))
                    .textFieldStyle(.plain).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(SC.text).frame(maxWidth: 380)
                Text("\(clock(ed.editedLength)) · \(ed.size.ratio) · \(ed.timeline.clips.count) clip\(ed.timeline.clips.count == 1 ? "" : "s")")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(SC.faint)
            }
            Spacer()
            if let p = ed.transcribing { statusPill("Writing captions", p) }
            if let ex = ed.exporting { statusPill("Saving \(ex.size.ratio)", ex.progress) }
            Menu {
                SwiftUI.Picker("Look", selection: $theme) {
                    Label("Match my Mac", systemImage: "circle.lefthalf.filled").tag("auto")
                    Label("Light", systemImage: "sun.max").tag("light")
                    Label("Dark", systemImage: "moon").tag("dark")
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: dark ? "moon.fill" : "sun.max.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(SC.dim)
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Light or dark editor")
            HStack(spacing: 2) {
                IconButton(icon: "arrow.uturn.backward", help: "Undo (⌘Z)") { ed.undoLast() }.disabled(!ed.canUndo)
                IconButton(icon: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { ed.redoLast() }.disabled(!ed.canRedo)
            }
            .padding(3).background(Capsule().fill(SC.wash(0.05))).overlay(Capsule().strokeBorder(SC.line))
            GlowButton(title: ed.exporting == nil ? "Export" : "Saving…", icon: "square.and.arrow.up") { showExport = true }
                .disabled(ed.analysis == nil)
                .popover(isPresented: $showExport, arrowEdge: .bottom) { ExportSheet(ed: ed) }
        }
        .padding(.leading, 78).padding(.trailing, 16)   // room for the window's buttons
        .frame(height: 54)
        .background(SC.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(SC.line).frame(height: 1) }
    }

    private func statusPill(_ label: String, _ p: Double) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(SC.wash(0.12), lineWidth: 2.5)
                Circle().trim(from: 0, to: p).stroke(SC.gradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 15, height: 15)
            Text("\(label) \(Int(p * 100))%").font(.system(size: 11.5, weight: .medium)).foregroundStyle(SC.dim)
        }
        .padding(.horizontal, 11).frame(height: 28).background(Capsule().fill(SC.wash(0.05)))
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: Tools

    private var rail: some View {
        // Scrolls rather than making the window taller when it's short.
        ScrollView(showsIndicators: false) {
            VStack(spacing: 3) {
                Button { showAdd = true } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SC.gradient))
                            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.white.opacity(0.25)))
                            .shadow(color: SC.accent.opacity(0.55), radius: 10, y: 3)
                        Text("Add").font(.system(size: 10, weight: .semibold)).foregroundStyle(SC.text)
                    }
                    .frame(width: 62, height: 62)
                }
                .buttonStyle(Springy(hoverScale: 1.06))
                .help("Add text, zooms, videos, pictures or music")
                .popover(isPresented: $showAdd, arrowEdge: .trailing) { AddMenu(ed: ed) { showAdd = false } }
                Rectangle().fill(SC.line).frame(width: 34, height: 1).padding(.vertical, 6)
                ForEach(StudioTool.allCases) { t in
                    RailButton(tool: t, selected: ed.tool == t, pill: railPill) { withAnimation(SC.spring) { ed.tool = t } }
                }
            }
            .padding(.vertical, 10)
        }
        .frame(width: 74)
        .frame(maxHeight: .infinity)
        .background(SC.panel)
        .overlay(alignment: .trailing) { Rectangle().fill(SC.line).frame(width: 1) }
    }

    // MARK: Preview

    private var stage: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    ForEach(ReelSize.allCases) { s in
                        ShapeChip(size: s, selected: ed.size == s, pill: shapePill) { withAnimation(SC.spring) { ed.size = s } }
                    }
                }
                .padding(3).background(Capsule().fill(SC.wash(0.05))).overlay(Capsule().strokeBorder(SC.line))
                Spacer()
                if let e = ed.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(.orange).lineLimit(2)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(Color.orange.opacity(0.12)))
                        .onTapGesture { ed.error = nil }
                }
            }
            GeometryReader { geo in
                let fit = fitted(ed.aspect, in: geo.size)
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black)
                    if ed.analysis != nil {
                        PlayerView(player: ed.player)
                        StageOverlay(ed: ed, viewSize: fit)
                    } else {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text(ed.status ?? "").font(.system(size: 13)).foregroundStyle(SC.dim)
                        }
                    }
                }
                .frame(width: fit.width, height: fit.height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SC.wash(0.1)))
                .shadow(color: SC.shadow, radius: 30, y: 14)
                .shadow(color: SC.accent.opacity(0.16), radius: 60)
                .animation(SC.spring, value: ed.aspect)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            transport
        }
        .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(stageLight)
    }

    /// A dark stage with a faint dot grid and a soft pool of the theme's light behind the video.
    private var stageLight: some View {
        ZStack {
            SC.bg
            RadialGradient(colors: [SC.accent.opacity(SC.dark ? 0.14 : 0.1), .clear], center: .center, startRadius: 20, endRadius: 520)
            Canvas { ctx, size in
                let step: CGFloat = 22
                var y: CGFloat = step / 2
                while y < size.height {
                    var x: CGFloat = step / 2
                    while x < size.width {
                        ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.4, height: 1.4)), with: .color(SC.wash(0.05)))
                        x += step
                    }
                    y += step
                }
            }
        }
    }

    private func fitted(_ aspect: CGFloat, in s: CGSize) -> CGSize {
        guard s.width > 0, s.height > 0, aspect > 0 else { return .zero }
        return s.width / s.height > aspect ? CGSize(width: s.height * aspect, height: s.height) : CGSize(width: s.width, height: s.width / aspect)
    }

    private var transport: some View {
        VStack(spacing: 4) {
            Scrubber(ed: ed).padding(.horizontal, 6).padding(.top, 8)
            controls
        }
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial).opacity(0.7))
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SC.raised.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(SC.edge))
        .frame(maxWidth: 620)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text(clock(ed.time)).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(SC.text).frame(width: 74, alignment: .leading)
            Spacer()
            IconButton(icon: "backward.end.fill", help: "Previous cut") { ed.jump(-1) }
            IconButton(icon: "gobackward.5", help: "Back 5 seconds") { ed.player.pause(); ed.seek(ed.time - 5) }
            Button { ed.togglePlay() } label: {
                Image(systemName: ed.playing ? "pause.fill" : "play.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44).background(Circle().fill(SC.gradient))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25)))
                    .shadow(color: SC.accent.opacity(ed.playing ? 0.7 : 0.45), radius: ed.playing ? 16 : 10)
                    .animation(SC.spring, value: ed.playing)
            }
            .buttonStyle(Springy(hoverScale: 1.07)).help("Play or pause (Space)")
            IconButton(icon: "goforward.5", help: "Forward 5 seconds") { ed.player.pause(); ed.seek(ed.time + 5) }
            IconButton(icon: "forward.end.fill", help: "Next cut") { ed.jump(1) }
            Spacer()
            Text(clock(ed.editedLength)).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(SC.faint)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 4).frame(height: 52)
    }

    private var timelineDivider: some View {
        ZStack {
            Rectangle().fill(SC.line).frame(height: 1)
            Capsule().fill(SC.wash(0.18)).frame(width: 36, height: 4)
        }
        .frame(height: 9)
        .background(SC.panel)
        .contentShape(Rectangle())
        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
        .gesture(DragGesture(minimumDistance: 1).onChanged { v in
            timelineHeight = min(440, max(170, timelineHeight - v.translation.height))
        })
    }

    // MARK: Keyboard

    private func installKeys() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak ed] e in
            guard let ed, let window = e.window, window.isKeyWindow else { return e }
            // Typing in a text box keeps its keys.
            if let r = window.firstResponder as? NSTextView, r.isEditable { return e }
            if window.firstResponder is TranscriptTextView, [51, 117].contains(e.keyCode) { return e }
            let cmd = e.modifierFlags.contains(.command), shift = e.modifierFlags.contains(.shift)
            switch (e.keyCode, e.charactersIgnoringModifiers?.lowercased() ?? "") {
            case (49, _): ed.togglePlay()
            case (123, _): if cmd { ed.seek(0) } else if shift { ed.step(frames: -1) } else { ed.seek(ed.time - 5) }
            case (124, _): if cmd { ed.seek(ed.editedLength) } else if shift { ed.step(frames: 1) } else { ed.seek(ed.time + 5) }
            case (51, _), (117, _): ed.deleteSelection()
            case (53, _): ed.selection = .none; NSApp.keyWindow?.makeFirstResponder(nil)
            case (_, "z") where cmd: if shift { ed.redoLast() } else { ed.undoLast() }
            case (_, "d") where cmd: ed.duplicateSelection()
            case (_, "a") where cmd: ed.selectRange(0, ed.editedLength)
            case (_, "s") where !cmd: ed.split()
            case (_, "b") where cmd: ed.split()
            case (_, "t") where !cmd: ed.addText(ReelEditor.textPresets[0].item)
            case (_, "z") where !cmd: ed.addZoom()
            case (_, "k") where !cmd: ed.player.pause()
            case (_, "l") where !cmd: ed.togglePlay()
            case (_, "j") where !cmd: ed.player.pause(); ed.seek(ed.time - 2)
            default: return e
            }
            return nil
        }
    }
}

func clock(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00.0" }
    let tenths = Int((s * 10).rounded(.down))
    let m = tenths / 600, sec = tenths / 10 % 60, d = tenths % 10
    return m >= 60 ? String(format: "%d:%02d:%02d.%d", m / 60, m % 60, sec, d) : String(format: "%d:%02d.%d", m, sec, d)
}

// MARK: - Pieces of the page

struct IconButton: View {
    let icon: String
    var help = ""
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold))
                .foregroundStyle(enabled ? (hover ? SC.text : SC.dim) : SC.faint.opacity(0.5))
                .frame(width: 30, height: 30)
                .background(Circle().fill(hover && enabled ? SC.wash(0.09) : .clear))
        }
        .buttonStyle(Springy(hoverScale: 1.08)).help(help).onHover { hover = $0 }
    }
}

struct RailButton: View {
    let tool: StudioTool
    let selected: Bool
    let pill: Namespace.ID
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tool.icon).font(.system(size: 15, weight: selected ? .semibold : .regular)).frame(height: 18)
                    .foregroundStyle(selected ? AnyShapeStyle(SC.gradient) : AnyShapeStyle(hover ? SC.text : SC.dim))
                    .symbolEffect(.bounce, value: selected)
                Text(tool.label).font(.system(size: 9.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? SC.text : (hover ? SC.text : SC.dim))
            }
            .frame(width: 62, height: 48)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SC.wash(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(SC.edge))
                        .overlay(alignment: .leading) {
                            Capsule().fill(SC.gradient).frame(width: 3, height: 20).offset(x: -6).shadow(color: SC.accent, radius: 4)
                        }
                        .matchedGeometryEffect(id: "rail", in: pill)
                } else if hover {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SC.wash(0.04))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Springy(hoverScale: 1.04)).onHover { hover = $0 }
    }
}

/// A shape choice in the segmented control above the preview.
struct ShapeChip: View {
    let size: ReelSize
    let selected: Bool
    let pill: Namespace.ID
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: size.icon).font(.system(size: 11, weight: .semibold))
                Text(size.ratio).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(selected ? .white : SC.dim)
            .padding(.horizontal, 12).frame(height: 28)
            .background {
                if selected {
                    Capsule().fill(SC.gradient).shadow(color: SC.accent.opacity(0.5), radius: 8).matchedGeometryEffect(id: "shape", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(Springy()).help(size.use)
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}

/// Everything you can put in the video, in one place.
struct AddMenu: View {
    @ObservedObject var ed: ReelEditor
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Add to your video").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(SC.text)
                Text("Or drop files anywhere on the editor.").font(.system(size: 11.5)).foregroundStyle(SC.dim)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                AddTile(title: "Text", icon: "textformat", tint: "8B5CF6", subtitle: "Titles, labels") { done(); ed.addText(ReelEditor.textPresets[0].item) }
                AddTile(title: "Zoom", icon: "plus.magnifyingglass", tint: "14B8A6", subtitle: "Push in") { done(); ed.addZoom() }
                AddTile(title: "Video", icon: "film", tint: "3B82F6", subtitle: "On top, B-roll") { done(); openPanel([.movie]) { ed.addVideo($0) } }
                AddTile(title: "Picture", icon: "photo", tint: "F59E0B", subtitle: "Logo, photo") { done(); openPanel([.image]) { ed.addImage($0) } }
                AddTile(title: "Music", icon: "music.note", tint: "EC4899", subtitle: "Dips for voice") { done(); openPanel([.audio]) { ed.setMusic($0) } }
                AddTile(title: "Subtitles", icon: "captions.bubble", tint: "22C55E", subtitle: "Styles") { done(); ed.change { $0.captions = true }; ed.tool = .captions }
                AddTile(title: "Blur", icon: "eye.slash", tint: "EF4444", subtitle: "Hide a name") { done(); ed.addBlur() }
                AddTile(title: "Filter", icon: "camera.filters", tint: "06B6D4", subtitle: "Film looks") { done(); ed.tool = .colour }
                AddTile(title: "Progress bar", icon: "chart.bar.fill", tint: "A855F7", subtitle: "Keeps them watching") { done(); ed.change { $0.progressBar = $0.progressBar ?? ProgressBar() }; ed.tool = .media }
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(SC.panel)
        .environment(\.colorScheme, .dark)
        .presentationBackground(SC.panel)
    }
}

/// Handles on the preview: click a text, picture or video to pick it, drag it to move it.
struct StageOverlay: View {
    @ObservedObject var ed: ReelEditor
    let viewSize: CGSize
    @State private var dragStart: CGPoint?

    var body: some View {
        let s = ed.timeline.source(at: ed.time)
        let k = viewSize.width / max(1, ed.renderSize.width)
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onTapGesture { ed.selection = .none }
            ForEach(ed.plan.videos.filter { s >= $0.start && s < $0.end && !$0.full }) { item in
                let w = viewSize.width * item.width
                let h = w / max(0.1, item.aspect)
                handle(selected: ed.selection == .video(item.id), size: CGSize(width: w, height: h))
                    .position(x: viewSize.width * item.x, y: viewSize.height * item.y)
                    .onTapGesture { ed.select(.video(item.id)) }
                    .gesture(move(.video(item.id), x: item.x, y: item.y))
            }
            ForEach(ed.plan.images.filter { s >= $0.start && s < $0.end }) { item in
                let w = viewSize.width * item.width
                let h = w * aspect(of: item)
                handle(selected: ed.selection == .image(item.id), size: CGSize(width: w, height: h))
                    .position(x: viewSize.width * item.x, y: viewSize.height * item.y)
                    .onTapGesture { ed.select(.image(item.id)) }
                    .gesture(move(.image(item.id), x: item.x, y: item.y))
            }
            ForEach(ed.plan.texts.filter { s >= $0.start - 0.001 && s < $0.end }) { item in
                let box = StudioType.box(item, frame: ed.renderSize)
                handle(selected: ed.selection == .text(item.id), size: CGSize(width: box.width * k, height: box.height * k))
                    .position(x: viewSize.width * item.x, y: viewSize.height * item.y)
                    .onTapGesture { ed.select(.text(item.id)) }
                    .gesture(move(.text(item.id), x: item.x, y: item.y))
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
    }

    private static var aspects: [String: CGFloat] = [:]
    private func aspect(of item: ImageItem) -> CGFloat {
        if let a = Self.aspects[item.file] { return a }
        guard let img = NSImage(contentsOfFile: item.file), img.size.width > 0 else { return 1 }
        let a = img.size.height / img.size.width
        Self.aspects[item.file] = a
        return a
    }

    private func handle(selected: Bool, size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.001))
            .frame(width: max(24, size.width), height: max(18, size.height))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(SC.gradient, lineWidth: 2).opacity(selected ? 1 : 0))
            .shadow(color: selected ? SC.accent.opacity(0.6) : .clear, radius: 6)
            .overlay(alignment: .topLeading) { if selected { dot } }
            .overlay(alignment: .topTrailing) { if selected { dot } }
            .overlay(alignment: .bottomLeading) { if selected { dot } }
            .overlay(alignment: .bottomTrailing) { if selected { dot } }
            .animation(SC.spring, value: selected)
            .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
    }

    private var dot: some View {
        Circle().fill(Color.white).frame(width: 8, height: 8).overlay(Circle().stroke(SC.accent, lineWidth: 2)).padding(-4)
    }

    private func move(_ sel: Selection, x: Double, y: Double) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if dragStart == nil { dragStart = CGPoint(x: x, y: y); ed.beginChange(); ed.select(sel) }
                guard let o = dragStart else { return }
                var nx = o.x + v.translation.width / viewSize.width, ny = o.y + v.translation.height / viewSize.height
                // Snap to the middle.
                if abs(nx - 0.5) < 0.012 { nx = 0.5 }
                if abs(ny - 0.5) < 0.012 { ny = 0.5 }
                nx = min(1, max(0, nx)); ny = min(1, max(0, ny))
                switch sel {
                case .text(let id): if let i = ed.plan.texts.firstIndex(where: { $0.id == id }) { ed.plan.texts[i].x = nx; ed.plan.texts[i].y = ny }
                case .image(let id): if let i = ed.plan.images.firstIndex(where: { $0.id == id }) { ed.plan.images[i].x = nx; ed.plan.images[i].y = ny }
                case .video(let id): if let i = ed.plan.videos.firstIndex(where: { $0.id == id }) { ed.plan.videos[i].x = nx; ed.plan.videos[i].y = ny }
                default: break
                }
            }
            .onEnded { _ in dragStart = nil }
    }
}

/// Where and how to save.
struct ExportSheet: View {
    @ObservedObject var ed: ReelEditor

    /// Roughly how big the file will be, from the length and the picture size.
    private func estimate(_ s: ReelSize) -> String {
        let px = s.render(source: CGSize(width: 1920, height: 1080))
        let mbps = 9.0 * Double(px.width * px.height) / (1920 * 1080) * ed.resolution * ed.resolution
        let mb = ed.editedLength * mbps / 8
        return mb >= 1000 ? String(format: "≈ %.1f GB", mb / 1000) : "≈ \(max(1, Int(mb.rounded()))) MB"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SC.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Export").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(SC.text)
                    Text("Tick the ones you need. Only those are saved.").font(.system(size: 11.5)).foregroundStyle(SC.dim)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("WHERE IT'S GOING").font(.system(size: 10.5, weight: .bold)).tracking(0.9).foregroundStyle(SC.dim)
                ForEach(ReelSize.allCases) { s in
                    let on = ed.toSave.contains(s)
                    Button {
                        withAnimation(SC.spring) { if on { ed.toSave.remove(s) } else { ed.toSave.insert(s) } }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 15))
                                .foregroundStyle(on ? AnyShapeStyle(SC.gradient) : AnyShapeStyle(SC.faint))
                            Image(systemName: s.icon).font(.system(size: 12)).foregroundStyle(SC.dim).frame(width: 16)
                            Text(s.ratio).font(.system(size: 13, weight: .semibold)).foregroundStyle(SC.text).frame(width: 64, alignment: .leading)
                            Text(s.use).font(.system(size: 12)).foregroundStyle(SC.dim).lineLimit(1)
                            Spacer()
                            Text(estimate(s)).font(.system(size: 11, design: .monospaced)).foregroundStyle(SC.faint)
                        }
                        .padding(.horizontal, 10).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? SC.wash(0.07) : SC.wash(0.02)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? SC.lineStrong : SC.line))
                    }
                    .buttonStyle(Springy(hoverScale: 1.01))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("QUALITY").font(.system(size: 10.5, weight: .bold)).tracking(0.9).foregroundStyle(SC.dim)
                Chips(options: [(2.0 / 3.0, "720p"), (1.0, "1080p"), (2.0, "4K")], selection: $ed.resolution)
            }
            Toggle("Move the original to the Bin afterwards", isOn: $ed.replaceOriginal).toggleStyle(.checkbox).font(.system(size: 12.5)).foregroundStyle(SC.dim)
            if let ex = ed.exporting {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(SC.wash(0.08))
                            Capsule().fill(SC.gradient).frame(width: max(6, g.size.width * ex.progress)).shadow(color: SC.accent.opacity(0.6), radius: 6)
                        }
                    }
                    .frame(height: 6)
                    Text("Saving \(ex.size.ratio)… \(Int(ex.progress * 100))%").font(.system(size: 11.5)).foregroundStyle(SC.dim)
                }
            } else if !ed.saved.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).symbolEffect(.bounce, value: ed.saved.count)
                    Text("\(ed.saved.count) video\(ed.saved.count == 1 ? "" : "s") saved").font(.system(size: 12.5, weight: .medium)).foregroundStyle(SC.text)
                    Spacer()
                    GhostButton(title: "Show", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting(ed.saved) }
                }
            }
            HStack {
                Text("Saved to Bubble Recordings › Reels").font(.system(size: 11)).foregroundStyle(SC.faint)
                Spacer()
                GlowButton(title: ed.toSave.isEmpty ? "Pick a shape" : "Export \(ed.toSave.count == 1 ? "1 video" : "\(ed.toSave.count) videos")", icon: "square.and.arrow.down") { ed.save() }
                    .disabled(ed.exporting != nil || ed.toSave.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(SC.panel)
        .environment(\.colorScheme, .dark)
        .presentationBackground(SC.panel)
    }
}

/// The progress bar under the preview: drag it, or click anywhere on it, to move through the video.
struct Scrubber: View {
    @ObservedObject var ed: ReelEditor
    @State private var hover = false
    @State private var dragging = false
    @State private var hoverX: CGFloat?
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let f = CGFloat(ed.editedLength > 0 ? min(1, ed.time / ed.editedLength) : 0)
            let tall = hover || dragging
            ZStack(alignment: .leading) {
                Capsule().fill(SC.wash(0.12)).frame(height: tall ? 7 : 4)
                // The clips, as faint gaps in the bar.
                ForEach(Array(ed.timeline.clips.dropFirst().enumerated()), id: \.offset) { _, c in
                    Rectangle().fill(SC.raised).frame(width: 2, height: tall ? 7 : 4).offset(x: w * CGFloat(c.out.start / max(0.01, ed.editedLength)) - 1)
                }
                Capsule().fill(SC.gradient).frame(width: max(4, f * w), height: tall ? 7 : 4).shadow(color: SC.accent.opacity(0.5), radius: tall ? 5 : 2)
                if let hx = hoverX, hover, !dragging {
                    Text(clock(Double(hx / max(1, w)) * ed.editedLength)).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.black.opacity(0.75)))
                        .fixedSize().offset(x: min(max(0, hx - 24), w - 52), y: -16)
                }
                Circle().fill(Color.white).frame(width: tall ? 15 : 0, height: tall ? 15 : 0)
                    .overlay(Circle().strokeBorder(SC.gradient, lineWidth: 3))
                    .shadow(color: SC.accent.opacity(0.7), radius: 5)
                    .offset(x: f * w - (tall ? 7.5 : 0))
            }
            .frame(height: 18)
            .animation(SC.spring, value: tall)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = true; hoverX = p.x
                case .ended: hover = false; hoverX = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !dragging { dragging = true; ed.player.pause() }
                    ed.seek(Double(min(1, max(0, v.location.x / max(1, w)))) * ed.editedLength)
                }
                .onEnded { _ in dragging = false })
        }
        .frame(height: 18)
        .help("Drag to move through the video")
    }
}
