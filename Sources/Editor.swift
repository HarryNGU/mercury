// The reel editor: a video editor for one recording, in the spirit of VEED. Mercury cuts the pauses straight
// away and writes captions; you trim, split and speed up clips on the timeline, cut words from the
// transcript, add text, zoom moments, pictures and music, style the canvas and colour, or ask Claude in
// the chat ("cut the part about pricing", "add a title"). Saving writes the videos to Mercury Recordings/Reels.
//
// This file holds ReelEditor, the model behind the page. ReelAssistant.swift is the Claude chat that edits,
// EditorPage.swift is the page itself and EditorPieces.swift has the smaller views it is built from.

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
            if a.words == nil || (a.engine != Whisper.engineTag && Whisper.ready) { await transcribe() }
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
                a.engine = Whisper.engineTag
            } catch {
                log("whisper: \(error.localizedDescription)")
                self.error = "Whisper couldn't transcribe this one, so captions use Apple's recognition."
            }
        }
        if a.engine?.hasPrefix("whisper") != true {
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
        if whisperReady, analysis?.engine != Whisper.engineTag { Task { await transcribe() } }
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

    // MARK: Placing things in time

    /// Where the picked text, zoom, picture, video or blur sits on the edited timeline.
    var selectionSpan: TimeSpan? {
        func out(_ a: Double, _ b: Double) -> TimeSpan? { timeline.outputSpan(of: TimeSpan(start: a, end: b)) }
        switch selection {
        case .text(let id): return plan.texts.first { $0.id == id }.flatMap { out($0.start, $0.end) }
        case .zoom(let id): return plan.zooms.first { $0.id == id }.flatMap { out($0.start, $0.end) }
        case .image(let id): return plan.images.first { $0.id == id }.flatMap { out($0.start, $0.end) }
        case .video(let id): return plan.videos.first { $0.id == id }.flatMap { out($0.start, $0.end) }
        case .blur(let id): return plan.blurs.first { $0.id == id }.flatMap { out($0.start, $0.end) }
        default: return nil
        }
    }

    /// Puts the picked item at an exact start and length, kept inside the video.
    func placeSelection(start: Double, length: Double) {
        guard selectionSpan != nil else { return }
        let len = max(0.2, min(length, timeline.duration))
        let a = max(0, min(start, timeline.duration - len))
        beginChange()
        setSpan(selection, from: a, to: a + len)
    }

    /// Moves the picked item to the playhead, keeping its length.
    func moveSelectionHere() {
        guard let sp = selectionSpan else { return }
        placeSelection(start: time, length: sp.end - sp.start)
    }

    /// The picked item starts at the playhead and still ends where it did, if that leaves anything.
    func startSelectionHere() {
        guard let sp = selectionSpan else { return }
        if time < sp.end - 0.2 { placeSelection(start: time, length: sp.end - time) } else { moveSelectionHere() }
    }

    /// The picked item ends at the playhead.
    func endSelectionHere() {
        guard let sp = selectionSpan, time > sp.start + 0.2 else { return }
        placeSelection(start: sp.start, length: time - sp.start)
    }

    /// Small steps with the comma and full stop keys.
    func nudgeSelection(by dt: Double) {
        guard let sp = selectionSpan else { return }
        placeSelection(start: sp.start + dt, length: sp.end - sp.start)
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

    /// Keeps a copy of a picture or song with Mercury's edits, so the edit still works if the original moves.
    private func keep(_ file: URL) -> URL? {
        let dir = Analyzer.cacheURL(for: url, "x").deletingLastPathComponent().appendingPathComponent("Assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(file.lastPathComponent)")
        do { try FileManager.default.copyItem(at: file, to: dest); return dest } catch {
            self.error = "Couldn't add \(file.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    /// A picture starts at the playhead for five seconds, like everything else you add.
    func addImage(_ file: URL) {
        guard let kept = keep(file) else { return }
        let start = timeline.source(at: time)
        var end = timeline.source(at: min(timeline.duration, time + 5), preferEnd: true)
        if end - start < 0.5 { end = start + 5 }
        let item = ImageItem(file: kept.path, name: file.deletingPathExtension().lastPathComponent, start: start, end: end)
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

    /// Writes the chosen shapes to Mercury Recordings/Reels, then (if asked) moves the original to the Bin.
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
                let name = "\(safe.isEmpty ? "Reel" : safe) · \(size.fileTag)"
                var out = Settings.reelsFolder.appendingPathComponent("\(name).mp4")
                var copy = 2
                // Re-editing a saved reel: never write over the video it's being read from.
                while out.standardizedFileURL == url.standardizedFileURL {
                    out = Settings.reelsFolder.appendingPathComponent("\(name) \(copy).mp4")
                    copy += 1
                }
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
