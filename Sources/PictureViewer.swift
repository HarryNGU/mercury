// Pictures in the Mercury chat open right inside the chat, the way they do in a messaging app.
// Click a picture, or pinch on it with the trackpad, and it fills the chat card. Pinch or use a
// mouse wheel to zoom, two fingers or a drag to move around, and Esc or a click outside to close.
// Nothing here leaves your Mac. Web pictures are only downloaded again at full size for viewing.

import SwiftUI
import AppKit

/// Which picture is open, and which pictures are on screen so a pinch can find the one under the pointer.
@MainActor
final class PictureViewer: ObservableObject {
    static let shared = PictureViewer()

    struct Item: Identifiable {
        let id = UUID()
        var image: NSImage
        /// A sharper copy to fetch when a small preview is opened.
        var fullSize: URL?
        /// Where "Open" goes: the file, or the page the picture came from.
        var open: URL?
        var openLabel: String
    }

    @Published var item: Item?
    /// How far you've zoomed, where 100 means the picture just fits.
    @Published var percent = 100
    @Published var fullScreen = false
    weak var scroll: ZoomScrollView?
    private var spots: [UUID: (rect: CGRect, item: Item)] = [:]
    /// Pinching that happened before the viewer finished opening.
    private var waiting: (factor: CGFloat, point: NSPoint)?

    func show(_ new: Item) {
        item = new
        percent = 100
        guard let url = new.fullSize else { return }
        Task {
            guard let big = await PictureFetch.image(url), item?.id == new.id else { return }
            item?.image = big
        }
    }

    func close() {
        item = nil
        waiting = nil
        if fullScreen { MediaFullScreen.shared.close() }
    }

    /// Swaps between filling the chat and filling the whole screen.
    func toggleFullScreen() {
        if fullScreen { MediaFullScreen.shared.close(); return }
        fullScreen = true
        MediaFullScreen.shared.show(AnyView(FullPicture(viewer: self))) { [weak self] in self?.fullScreen = false }
    }

    func mark(_ id: UUID, rect: CGRect, item: Item) { spots[id] = (rect, item) }
    func unmark(_ id: UUID) { spots[id] = nil }

    /// The panel's scroll view asks for this once it exists, so a pinch that opened it carries straight on.
    func viewerReady(_ view: ZoomScrollView) {
        scroll = view
        if let w = waiting { view.zoom(by: w.factor, at: w.point); waiting = nil }
    }

    /// Every pinch in the chat comes through here. True means it was used.
    func pinch(amount: CGFloat, at point: NSPoint, windowHeight: CGFloat) -> Bool {
        if item != nil {
            if let scroll { scroll.zoom(by: 1 + amount, at: point) }
            else { waiting = ((waiting?.factor ?? 1) * (1 + amount), point) }
            return true
        }
        guard amount > 0 else { return false }
        let flipped = CGPoint(x: point.x, y: windowHeight - point.y)
        guard let hit = spots.values.first(where: { $0.rect.contains(flipped) }) else { return false }
        waiting = (1 + amount, point)
        show(hit.item)
        return true
    }

    /// Closes what's open on top of the chat. False when nothing was.
    func closeIfOpen() -> Bool {
        guard item != nil else { return false }
        close()
        return true
    }
}

/// Keeps a picture in the middle while it's smaller than the space around it.
final class CentredClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let d = documentView else { return r }
        if r.width > d.frame.width { r.origin.x = (d.frame.width - r.width) / 2 }
        if r.height > d.frame.height { r.origin.y = (d.frame.height - r.height) / 2 }
        return r
    }
}

/// The picture itself: drag it to move around, double click to zoom in or back out.
final class PanImageView: NSImageView {
    private var last = NSPoint.zero
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with e: NSEvent) {
        last = e.locationInWindow
        if e.clickCount == 2, let s = enclosingScrollView as? ZoomScrollView { s.toggleZoom(at: e.locationInWindow) }
    }
    override func mouseDragged(with e: NSEvent) {
        guard let s = enclosingScrollView else { return }
        let dx = (e.locationInWindow.x - last.x) / s.magnification, dy = (e.locationInWindow.y - last.y) / s.magnification
        last = e.locationInWindow
        var o = s.contentView.bounds.origin
        o.x -= dx; o.y -= dy
        s.contentView.scroll(to: s.contentView.constrainBoundsRect(NSRect(origin: o, size: s.contentView.bounds.size)).origin)
        s.reflectScrolledClipView(s.contentView)
        NSCursor.closedHand.set()
    }
    override func mouseUp(with e: NSEvent) { NSCursor.openHand.set() }
}

/// A native scroll view so pinching and two finger moves feel like the rest of the Mac.
final class ZoomScrollView: NSScrollView {
    var onBackdropClick: (() -> Void)?
    var onZoom: ((Int) -> Void)?
    private(set) var fit: CGFloat = 1
    private var atFit = true
    private let picture = PanImageView()
    private var shownImage: NSImage?
    private var lastSize = CGSize.zero

    convenience init(image: NSImage) {
        self.init(frame: .zero)
        contentView = CentredClipView()
        drawsBackground = false
        contentView.drawsBackground = false
        automaticallyAdjustsContentInsets = false
        hasHorizontalScroller = true; hasVerticalScroller = true; autohidesScrollers = true; scrollerStyle = .overlay
        allowsMagnification = true
        picture.imageScaling = .scaleAxesIndependently
        picture.wantsLayer = true
        picture.layer?.backgroundColor = NSColor.white.cgColor   // diagrams with see-through backgrounds stay readable
        documentView = picture
        show(image)
    }

    private static func pixels(_ i: NSImage) -> CGSize {
        let w = i.representations.map(\.pixelsWide).max() ?? 0, h = i.representations.map(\.pixelsHigh).max() ?? 0
        return w > 0 && h > 0 ? CGSize(width: w, height: h) : i.size
    }

    /// Swaps in a picture. When a sharper copy arrives, you stay on the same spot at the same zoom.
    func show(_ image: NSImage) {
        guard image !== shownImage else { return }
        let size = Self.pixels(image), oldWidth = picture.frame.width
        let hadPicture = shownImage != nil && oldWidth > 0
        let ratio = hadPicture ? size.width / oldWidth : 1
        let origin = contentView.bounds.origin, mag = magnification
        shownImage = image
        picture.image = image
        picture.frame = NSRect(origin: .zero, size: size)
        refit()
        if hadPicture, !atFit {
            magnification = max(minMagnification, min(maxMagnification, mag / ratio))
            contentView.scroll(to: NSPoint(x: origin.x * ratio, y: origin.y * ratio))
            reflectScrolledClipView(contentView)
        }
    }

    override func layout() {
        super.layout()
        if frame.size != lastSize { lastSize = frame.size; refit() }
    }

    private func refit() {
        let d = picture.frame.size
        guard frame.width > 0, frame.height > 0, d.width > 0, d.height > 0 else { return }
        fit = min(frame.width / d.width, frame.height / d.height)
        minMagnification = fit
        maxMagnification = max(fit * 12, 6)
        if atFit { magnification = fit }
        report()
    }

    private func report() { onZoom?(Int((magnification / fit * 100).rounded())) }

    func zoom(by factor: CGFloat, at windowPoint: NSPoint?) {
        let target = max(minMagnification, min(maxMagnification, magnification * factor))
        let c = contentView.bounds
        let p = windowPoint.map { contentView.convert($0, from: nil) } ?? NSPoint(x: c.midX, y: c.midY)
        setMagnification(target, centeredAt: p)
        atFit = abs(target - fit) < fit * 0.002
        report()
    }

    func showWhole() { atFit = true; magnification = fit; report() }

    func toggleZoom(at windowPoint: NSPoint?) {
        if atFit { zoom(by: 2.5, at: windowPoint) } else { showWhole() }
    }

    override func magnify(with e: NSEvent) { zoom(by: 1 + e.magnification, at: e.locationInWindow) }
    override func smartMagnify(with e: NSEvent) { toggleZoom(at: e.locationInWindow) }

    /// A mouse wheel zooms. A trackpad's two finger scroll moves around, as it does everywhere else.
    override func scrollWheel(with e: NSEvent) {
        if e.hasPreciseScrollingDeltas { super.scrollWheel(with: e); return }
        zoom(by: pow(1.06, e.scrollingDeltaY), at: e.locationInWindow)
    }

    override func mouseDown(with e: NSEvent) { onBackdropClick?() }
}

struct ZoomingPicture: NSViewRepresentable {
    let image: NSImage
    @ObservedObject var viewer: PictureViewer

    func makeNSView(context: Context) -> ZoomScrollView {
        let v = ZoomScrollView(image: image)
        let viewer = viewer
        v.onBackdropClick = { viewer.close() }
        v.onZoom = { p in DispatchQueue.main.async { if viewer.percent != p { viewer.percent = p } } }
        DispatchQueue.main.async { viewer.viewerReady(v) }
        return v
    }
    func updateNSView(_ v: ZoomScrollView, context: Context) { v.show(image) }
}

/// Fills the chat card while a picture is open.
struct PictureViewerOverlay: View {
    @ObservedObject var viewer: PictureViewer
    let item: PictureViewer.Item

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(white: 0.06)
            ZoomingPicture(image: item.image, viewer: viewer)
            HStack(spacing: 4) {
                control("minus", "Zoom out") { viewer.scroll?.zoom(by: 0.75, at: nil) }
                Button { viewer.scroll?.showWhole() } label: {
                    Text("\(viewer.percent)%").font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .frame(minWidth: 46).frame(height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Show the whole picture")
                control("plus", "Zoom in") { viewer.scroll?.zoom(by: 1.33, at: nil) }
                Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 16).padding(.horizontal, 3)
                control("doc.on.doc", "Copy picture") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([item.image])
                }
                if let url = item.open {
                    control("arrow.up.right.square", item.openLabel) { NSWorkspace.shared.open(url) }
                }
                control(viewer.fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        viewer.fullScreen ? "Exit full screen" : "Full screen") { viewer.toggleFullScreen() }
                control("xmark", "Close") { viewer.close() }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6).frame(height: 38)
            .background(Capsule().fill(Color(white: 0.16)))
            .overlay(Capsule().stroke(.white.opacity(0.16)))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
            .padding(10)
        }
    }

    private func control(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

/// The same viewer, filling the screen.
struct FullPicture: View {
    @ObservedObject var viewer: PictureViewer
    var body: some View {
        if let item = viewer.item { PictureViewerOverlay(viewer: viewer, item: item) } else { Color.black }
    }
}

/// Makes a picture in the chat open in the viewer when clicked or pinched.
private struct OpensInViewer: ViewModifier {
    let image: NSImage
    var fullSize: URL?
    var open: URL?
    var openLabel: String
    @State private var id = UUID()
    @State private var rect = CGRect.zero

    private var item: PictureViewer.Item { .init(image: image, fullSize: fullSize, open: open, openLabel: openLabel) }
    private func remember() { PictureViewer.shared.mark(id, rect: rect, item: item) }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { PictureViewer.shared.show(item) }
            .pointerStyle(.zoomIn)
            .help("Click or pinch to zoom")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect = $0; remember() }
            .onChange(of: image) { remember() }
            .onDisappear { PictureViewer.shared.unmark(id) }
    }
}

extension View {
    func opensInViewer(_ image: NSImage, fullSize: URL? = nil, open: URL?, openLabel: String) -> some View {
        modifier(OpensInViewer(image: image, fullSize: fullSize, open: open, openLabel: openLabel))
    }
}
