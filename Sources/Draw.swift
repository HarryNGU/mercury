// Drawing on the screen while recording: a see-through layer over the recorded screen that the video
// (and anyone watching a share) sees, and a small toolbar under the pill that it doesn't. Pens,
// a highlighter, ink that fades after a moment, lines, arrows, boxes and circles, shapes tidied up
// as you draw them, a lasso to move or delete, an eraser, undo and one button to clear it all.
// While drawing is on the layer takes the mouse; turn it off and you can use your apps again
// with the drawings left in place.

import AppKit
import Combine
import SwiftUI

enum DrawTool: String, CaseIterable {
    case pen, marker, fade, line, arrow, rect, ellipse, lasso, eraser
    var icon: String {
        switch self {
        case .pen: "pencil.tip"; case .marker: "highlighter"; case .fade: "scribble.variable"; case .line: "line.diagonal"
        case .arrow: "arrow.up.right"; case .rect: "rectangle"; case .ellipse: "circle"; case .lasso: "lasso"; case .eraser: "eraser"
        }
    }
    var tip: String {
        switch self {
        case .pen: "Pen"; case .marker: "Highlighter"; case .fade: "Disappearing ink: fades after a couple of seconds"
        case .line: "Straight line (hold Shift for 45°)"; case .arrow: "Arrow"; case .rect: "Box"; case .ellipse: "Circle"
        case .lasso: "Lasso: circle drawings to move or delete them"; case .eraser: "Eraser: rub out whole strokes"
        }
    }
}

struct Stroke: Identifiable {
    enum Kind { case free, line, arrow, rect, ellipse }
    let id = UUID()
    var kind: Kind
    var points: [CGPoint]          // view coordinates
    var color: NSColor
    var width: CGFloat
    var marker = false
    var fades = false
    var born = Date()
    var finished = false

    var bounds: CGRect {
        guard let f = points.first else { return .zero }
        var r = CGRect(origin: f, size: .zero)
        for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
        return r.insetBy(dx: -width, dy: -width)
    }
}

@MainActor
final class DrawModel: ObservableObject {
    static let colors: [NSColor] = [.white, .black, NSColor(hex: "FF3B30"), NSColor(hex: "FFCC00"), NSColor(hex: "34C759"),
                                    NSColor(hex: "0A84FF"), NSColor(hex: "BF5AF2")]
    static let widths: [CGFloat] = [3, 6, 12]

    @Published var active = false
    @Published var tool: DrawTool = .pen
    @Published var color: NSColor = NSColor(hex: "FF3B30")
    @Published var width: CGFloat = 6
    @Published var autoShapes = true
    @Published var strokes: [Stroke] = [] { didSet { onChange?() } }
    @Published var selected: Set<UUID> = []
    private var history: [[Stroke]] = []
    var onChange: (() -> Void)?

    var hasDrawings: Bool { !strokes.isEmpty }

    func checkpoint() {
        history.append(strokes)
        if history.count > 100 { history.removeFirst() }
    }

    func undo() {
        guard let last = history.popLast() else { return }
        strokes = last
        selected = []
    }

    func clear() {
        guard !strokes.isEmpty else { return }
        checkpoint()
        strokes = []
        selected = []
    }

    func deleteSelected() {
        guard !selected.isEmpty else { return }
        checkpoint()
        strokes.removeAll { selected.contains($0.id) }
        selected = []
    }
}

// MARK: - Tidying a stroke into a shape

enum ShapeGuess {
    /// A straight line, a box or a circle, if the stroke was clearly meant as one.
    static func tidy(_ s: Stroke) -> Stroke {
        let pts = s.points
        guard pts.count > 8, let a = pts.first, let b = pts.last else { return s }
        let box = CGRect(x: pts.map(\.x).min()!, y: pts.map(\.y).min()!, width: 0, height: 0)
            .union(CGRect(x: pts.map(\.x).max()!, y: pts.map(\.y).max()!, width: 0, height: 0))
        let diag = hypot(box.width, box.height)
        guard diag > 30 else { return s }
        var out = s

        // Straight line: every point close to the line from start to end.
        let len = hypot(b.x - a.x, b.y - a.y)
        if len > diag * 0.9 {
            let dx: CGFloat = b.x - a.x, dy: CGFloat = b.y - a.y, c: CGFloat = b.x * a.y - b.y * a.x
            var worst: CGFloat = 0
            for p in pts { worst = max(worst, abs(dy * p.x - dx * p.y + c) / max(1, len)) }
            if worst < max(6, len * 0.05) {
                out.kind = .line
                out.points = [a, b]
                return out
            }
        }
        // A closed loop: is it a box or a circle?
        guard hypot(b.x - a.x, b.y - a.y) < diag * 0.25 else { return s }
        let cx = box.midX, cy = box.midY, rx = max(1, box.width / 2), ry = max(1, box.height / 2)
        var ellipseErr: CGFloat = 0, boxErr: CGFloat = 0
        let side = max(1, min(box.width, box.height))
        for p in pts {
            ellipseErr += abs(hypot((p.x - cx) / rx, (p.y - cy) / ry) - 1)
            let edge = min(min(abs(p.x - box.minX), abs(p.x - box.maxX)), min(abs(p.y - box.minY), abs(p.y - box.maxY)))
            boxErr += edge / side
        }
        ellipseErr /= CGFloat(pts.count)
        boxErr /= CGFloat(pts.count)
        if boxErr < 0.06 && boxErr < ellipseErr * 0.8 {
            out.kind = .rect
            out.points = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)]
        } else if ellipseErr < 0.16 {
            out.kind = .ellipse
            out.points = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)]
        }
        return out
    }
}

// MARK: - The layer you draw on

final class DrawWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class DrawView: NSView {
    let model: DrawModel
    private var current: Stroke?
    private var lasso: [CGPoint] = []
    private var dragFrom: CGPoint?
    private var timer: Timer?

    init(model: DrawModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: model.tool == .lasso ? .arrow : model.tool == .eraser ? .disappearingItem : .crosshair)
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch model.tool {
        case .eraser:
            model.checkpoint()
            erase(at: p)
        case .lasso:
            if !model.selected.isEmpty, selectionBounds.contains(p) {
                model.checkpoint()
                dragFrom = p
            } else {
                model.selected = []
                lasso = [p]
            }
        default:
            let kind: Stroke.Kind = switch model.tool {
            case .line: .line; case .arrow: .arrow; case .rect: .rect; case .ellipse: .ellipse; default: .free
            }
            let marker = model.tool == .marker
            current = Stroke(kind: kind, points: [p, p], color: model.color, width: marker ? model.width * 3 : model.width,
                             marker: marker, fades: model.tool == .fade)
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        var p = convert(e.locationInWindow, from: nil)
        switch model.tool {
        case .eraser: erase(at: p)
        case .lasso:
            if let from = dragFrom {
                let dx = p.x - from.x, dy = p.y - from.y
                for i in model.strokes.indices where model.selected.contains(model.strokes[i].id) {
                    model.strokes[i].points = model.strokes[i].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
                }
                dragFrom = p
            } else {
                lasso.append(p)
            }
        default:
            guard var s = current else { return }
            if s.kind == .free {
                if let last = s.points.last, hypot(p.x - last.x, p.y - last.y) < 1.5 { return }
                s.points.append(p)
            } else {
                // Shift keeps lines at 45° steps and boxes and circles even.
                if e.modifierFlags.contains(.shift), let a = s.points.first {
                    let dx = p.x - a.x, dy = p.y - a.y
                    if s.kind == .line || s.kind == .arrow {
                        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4), r = hypot(dx, dy)
                        p = CGPoint(x: a.x + cos(angle) * r, y: a.y + sin(angle) * r)
                    } else {
                        let m = max(abs(dx), abs(dy))
                        p = CGPoint(x: a.x + (dx < 0 ? -m : m), y: a.y + (dy < 0 ? -m : m))
                    }
                }
                s.points[1] = p
            }
            current = s
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        switch model.tool {
        case .lasso:
            if dragFrom != nil { dragFrom = nil } else {
                let path = NSBezierPath()
                if let f = lasso.first { path.move(to: f); lasso.dropFirst().forEach { path.line(to: $0) }; path.close() }
                model.selected = Set(model.strokes.filter { s in s.points.contains { path.contains($0) } }.map(\.id))
                lasso = []
            }
        case .eraser: break
        default:
            guard var s = current else { return }
            current = nil
            s.finished = true
            s.born = Date()
            if s.kind == .free && model.autoShapes && !s.marker && !s.fades { s = ShapeGuess.tidy(s) }
            let tiny = s.kind != .free && hypot(s.points[1].x - s.points[0].x, s.points[1].y - s.points[0].y) < 3
            if !tiny {
                model.checkpoint()
                model.strokes.append(s)
            }
            if s.fades { startFading() }
        }
        needsDisplay = true
    }

    private func erase(at p: CGPoint) {
        let r: CGFloat = 14
        let hit = model.strokes.filter { s in
            if s.kind == .free { return s.points.contains { hypot($0.x - p.x, $0.y - p.y) < r + s.width / 2 } }
            return s.bounds.insetBy(dx: -r, dy: -r).contains(p) && path(for: s).contains(p) || nearOutline(s, p, r)
        }.map(\.id)
        if !hit.isEmpty { model.strokes.removeAll { hit.contains($0.id) } }
    }

    private func nearOutline(_ s: Stroke, _ p: CGPoint, _ r: CGFloat) -> Bool {
        let outline = path(for: s).cgPath.copy(strokingWithWidth: s.width + r * 2, lineCap: .round, lineJoin: .round, miterLimit: 4)
        return outline.contains(p)
    }

    private var selectionBounds: CGRect {
        model.strokes.filter { model.selected.contains($0.id) }.map(\.bounds).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -8, dy: -8)
    }

    // MARK: Keys

    override func keyDown(with e: NSEvent) {
        let cmd = e.modifierFlags.contains(.command)
        switch (e.keyCode, e.charactersIgnoringModifiers?.lowercased() ?? "") {
        case (53, _): model.active = false                      // Esc: stop drawing
        case (51, _), (117, _): if model.selected.isEmpty { model.undo() } else { model.deleteSelected() }
        case (_, "z") where cmd: model.undo()
        case (_, "k") where cmd: model.clear()
        default:
            let keys: [String: DrawTool] = ["p": .pen, "h": .marker, "f": .fade, "l": .line, "a": .arrow, "r": .rect, "o": .ellipse, "s": .lasso, "e": .eraser]
            if !cmd, let t = keys[e.charactersIgnoringModifiers?.lowercased() ?? ""] { model.tool = t } else { super.keyDown(with: e) }
        }
        needsDisplay = true
    }

    // MARK: Fading ink

    func startFading() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                let gone = self.model.strokes.filter { $0.fades && now.timeIntervalSince($0.born) > Self.fadeHold + Self.fadeOut }.map(\.id)
                if !gone.isEmpty { self.model.strokes.removeAll { gone.contains($0.id) } }
                self.needsDisplay = true
                if !self.model.strokes.contains(where: \.fades) && self.current?.fades != true { self.timer?.invalidate(); self.timer = nil }
            }
        }
    }
    static let fadeHold = 1.6, fadeOut = 0.9

    // MARK: Drawing

    private func path(for s: Stroke) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = s.width
        let pts = s.points
        switch s.kind {
        case .free:
            guard let first = pts.first else { return path }
            path.move(to: first)
            if pts.count < 3 { pts.dropFirst().forEach { path.line(to: $0) }; return path }
            // Smooth: curve through the midpoints of each pair.
            for i in 1..<(pts.count - 1) {
                let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                path.curve(to: mid, controlPoint1: pts[i], controlPoint2: pts[i])
            }
            path.line(to: pts[pts.count - 1])
        case .line, .arrow:
            path.move(to: pts[0]); path.line(to: pts[1])
            if s.kind == .arrow {
                let a = pts[0], b = pts[1], ang = atan2(b.y - a.y, b.x - a.x), head = max(14, s.width * 4)
                for d in [CGFloat.pi * 0.83, -CGFloat.pi * 0.83] {
                    path.move(to: b)
                    path.line(to: CGPoint(x: b.x + cos(ang + d) * head, y: b.y + sin(ang + d) * head))
                }
            }
        case .rect, .ellipse:
            let r = CGRect(x: min(pts[0].x, pts[1].x), y: min(pts[0].y, pts[1].y), width: abs(pts[1].x - pts[0].x), height: abs(pts[1].y - pts[0].y))
            path.append(s.kind == .rect ? NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6) : NSBezierPath(ovalIn: r))
        }
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = Date()
        for s in model.strokes + (current.map { [$0] } ?? []) {
            var alpha: CGFloat = s.marker ? 0.38 : 1
            if s.fades && s.finished {
                let age = now.timeIntervalSince(s.born)
                if age > Self.fadeHold { alpha *= CGFloat(max(0, 1 - (age - Self.fadeHold) / Self.fadeOut)) }
            }
            let p = path(for: s)
            // A soft dark edge keeps light ink readable on light pages, and the other way round.
            if !s.marker {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.35 * alpha)
                shadow.shadowBlurRadius = 3
                shadow.set()
                s.color.withAlphaComponent(alpha).setStroke()
                p.stroke()
                NSGraphicsContext.restoreGraphicsState()
            } else {
                s.color.withAlphaComponent(alpha).setStroke()
                p.stroke()
            }
            if model.selected.contains(s.id) {
                NSColor.white.withAlphaComponent(0.8).setStroke()
                let r = NSBezierPath(roundedRect: s.bounds, xRadius: 4, yRadius: 4)
                r.setLineDash([5, 4], count: 2, phase: 0)
                r.lineWidth = 1
                r.stroke()
            }
        }
        if lasso.count > 1 {
            let l = NSBezierPath()
            l.move(to: lasso[0]); lasso.dropFirst().forEach { l.line(to: $0) }
            l.setLineDash([6, 4], count: 2, phase: 0)
            l.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.9).setStroke()
            l.stroke()
        }
    }
}

// MARK: - The toolbar (never recorded)

struct DrawToolbar: View {
    @ObservedObject var model: DrawModel
    var body: some View {
        HStack(spacing: 4) {
            ForEach([DrawTool.pen, .marker, .fade], id: \.self) { tool($0) }
            Menu {
                ForEach([DrawTool.line, .arrow, .rect, .ellipse], id: \.self) { t in
                    Button { model.tool = t } label: { Label(t.tip, systemImage: t.icon) }
                }
            } label: {
                Image(systemName: [.line, .arrow, .rect, .ellipse].contains(model.tool) ? model.tool.icon : "square.on.circle")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .frame(width: 30, height: 30)
            .background(Circle().fill([.line, .arrow, .rect, .ellipse].contains(model.tool) ? Color.white.opacity(0.22) : .clear))
            .help("Lines, arrows, boxes and circles")
            tool(.lasso)
            tool(.eraser)
            divider
            Button { model.autoShapes.toggle() } label: {
                Image(systemName: "wand.and.stars").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.autoShapes ? Color(nsColor: NSColor(hex: "FFCC00")) : .white.opacity(0.5))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain).help(model.autoShapes ? "Shapes tidy themselves: on" : "Shapes tidy themselves: off")
            divider
            ForEach(DrawModel.colors.indices, id: \.self) { i in
                let c = DrawModel.colors[i]
                Circle().fill(Color(nsColor: c)).frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                    .overlay(Circle().stroke(Color.white, lineWidth: 2).padding(-3).opacity(model.color == c ? 1 : 0))
                    .onTapGesture { model.color = c; if model.tool == .eraser || model.tool == .lasso { model.tool = .pen } }
                    .padding(.horizontal, 2)
            }
            divider
            ForEach(DrawModel.widths, id: \.self) { w in
                Circle().fill(Color.white).frame(width: 4 + w * 0.8, height: 4 + w * 0.8)
                    .frame(width: 22, height: 30)
                    .background(Circle().fill(model.width == w ? Color.white.opacity(0.2) : .clear).frame(width: 24, height: 24))
                    .contentShape(Rectangle())
                    .onTapGesture { model.width = w }
                    .help(["Thin", "Medium", "Thick"][DrawModel.widths.firstIndex(of: w) ?? 0])
            }
            divider
            icon("arrow.uturn.backward", "Undo (⌘Z)") { model.undo() }
            icon("trash", "Clear everything (⌘K)") { model.clear() }
                .disabled(!model.hasDrawings)
            Button { model.active = false } label: {
                Text("Done").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 28).background(Capsule().fill(Theme.brand))
            }
            .buttonStyle(.plain).help("Stop drawing (Esc). Your drawings stay until you clear them.")
            .padding(.leading, 2)
        }
        .padding(.horizontal, 8).frame(height: 44)
        .background(ZStack { VisualEffect(material: .hudWindow); Color.black.opacity(0.35) }.clipShape(Capsule()))
        .overlay(Capsule().stroke(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 22).padding(.horizontal, 3) }

    private func tool(_ t: DrawTool) -> some View {
        Button { model.tool = t } label: {
            Image(systemName: t.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(model.tool == t ? Color.white.opacity(0.22) : .clear))
        }
        .buttonStyle(.plain).help(t.tip)
    }

    private func icon(_ name: String, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).frame(width: 30, height: 30)
        }
        .buttonStyle(.plain).help(tip)
    }
}

// MARK: - Putting it on screen

@MainActor
final class DrawController {
    let model = DrawModel()
    private var window: DrawWindow?
    private var view: DrawView?
    private let toolbar: NSPanel
    private var watch: AnyCancellable?
    private var previousApp: NSRunningApplication?
    /// Called when the drawing layer appears or goes, so a window recording can include it.
    var onLayerChange: (() -> Void)?
    var onStateChange: (() -> Void)?

    init() {
        let host = FirstClickHostingView(rootView: DrawToolbar(model: model))
        let size = host.fittingSize
        toolbar = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        toolbar.isOpaque = false
        toolbar.alwaysDark()
        toolbar.backgroundColor = .clear
        toolbar.level = .statusBar
        toolbar.hasShadow = true
        toolbar.hidesOnDeactivate = false
        toolbar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        toolbar.sharingType = .none  // the tools are never recorded; the drawings are
        host.frame = NSRect(origin: .zero, size: size)
        toolbar.contentView = host
        watch = model.$active.dropFirst().sink { [weak self] on in DispatchQueue.main.async { self?.apply(on) } }
        model.onChange = { [weak self] in self?.view?.needsDisplay = true; self?.onStateChange?() }
    }

    var windowNumbers: [Int] { window.map { [$0.windowNumber] } ?? [] }
    var drawing: Bool { model.active }

    /// Turns drawing on over `screen` (the toolbar sits under the pill), or off again.
    func toggle(on screen: NSScreen, below pill: NSRect) {
        if window == nil || window?.screen != screen { makeLayer(on: screen) }
        model.active.toggle()
        if model.active {
            let s = toolbar.frame.size
            let x = min(max(screen.visibleFrame.minX + 8, pill.midX - s.width / 2), screen.visibleFrame.maxX - s.width - 8)
            toolbar.setFrameOrigin(NSPoint(x: x, y: pill.minY - s.height - 8))
        }
    }

    func clear() { model.clear() }

    /// When recording ends: everything goes.
    func reset() {
        model.active = false
        model.strokes = []
        model.selected = []
        window?.orderOut(nil)
        window = nil
        view = nil
        toolbar.orderOut(nil)
        onLayerChange?()
    }

    private func makeLayer(on screen: NSScreen) {
        window?.orderOut(nil)
        let w = DrawWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.ignoresMouseEvents = true
        let v = DrawView(model: model)
        v.frame = NSRect(origin: .zero, size: screen.frame.size)
        w.contentView = v
        w.setFrame(screen.frame, display: false)
        window = w
        view = v
        w.orderFrontRegardless()
        onLayerChange?()
    }

    private func apply(_ on: Bool) {
        guard let w = window else { return }
        w.ignoresMouseEvents = !on
        if on {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != getpid() { previousApp = front }
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(view)
            w.invalidateCursorRects(for: view!)
            toolbar.orderFrontRegardless()
        } else {
            toolbar.orderOut(nil)
            model.selected = []
            w.orderFrontRegardless()
            // Hand the keyboard back to whatever you were using.
            previousApp?.activate()
            previousApp = nil
        }
        view?.needsDisplay = true
        onStateChange?()
    }
}
