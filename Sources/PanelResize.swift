// Lets you make the Mercury panel any size: drag any edge or corner, pick a size from the menu,
// or fill the screen. Left alone, it still grows to fit the conversation as it always has.

import AppKit
import SwiftUI

enum PanelEdge: CaseIterable {
    case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight
    var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
    var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
    var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
}

enum PanelSizing {
    static let minimum = CGSize(width: 400, height: 260)

    /// The panel's frame after dragging `edge` by (dx, dy), in screen points where y goes up.
    /// The side you aren't dragging stays exactly where it is, even at the smallest size.
    static func resized(_ s: NSRect, edge: PanelEdge, dx: CGFloat, dy: CGFloat, within area: NSRect) -> NSRect {
        var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
        if edge.movesLeft { minX = min(max(area.minX, s.minX + dx), maxX - minimum.width) }
        if edge.movesRight { maxX = max(min(area.maxX, s.maxX + dx), minX + minimum.width) }
        if edge.movesBottom { minY = min(max(area.minY, s.minY + dy), maxY - minimum.height) }
        if edge.movesTop { maxY = max(min(area.maxY, s.maxY + dy), minY + minimum.height) }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A size that fits on this screen.
    static func clamp(_ size: CGSize, to area: NSRect) -> CGSize {
        CGSize(width: max(minimum.width, min(area.width, size.width)), height: max(minimum.height, min(area.height, size.height)))
    }
}

/// An invisible strip along an edge. It works in screen points from the mouse, not in the window's own
/// coordinates, because the window moves under the pointer while you drag.
final class PanelGripView: NSView {
    var edge = PanelEdge.right
    var onStart: (() -> Void)?
    var onDrag: ((NSRect) -> Void)?
    var onEnd: (() -> Void)?
    private var startFrame = NSRect.zero
    private var startMouse = NSPoint.zero
    private var area = NSRect.zero

    override var mouseDownCanMoveWindow: Bool { false }
    override var isOpaque: Bool { false }
    // Draws nothing. The grips sit just inside the bar and the chat card, so the panel's own glass catches the clicks.

    private var cursor: NSCursor {
        let position: NSCursor.FrameResizePosition
        switch edge {
        case .top: position = .top
        case .bottom: position = .bottom
        case .left: position = .left
        case .right: position = .right
        case .topLeft: position = .topLeft
        case .topRight: position = .topRight
        case .bottomLeft: position = .bottomLeft
        case .bottomRight: position = .bottomRight
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    override func mouseDown(with e: NSEvent) {
        guard let w = window else { return }
        startFrame = w.frame
        startMouse = NSEvent.mouseLocation
        area = (w.screen ?? NSScreen.underMouse).visibleFrame
        onStart?()
    }
    override func mouseDragged(with e: NSEvent) {
        let m = NSEvent.mouseLocation
        onDrag?(PanelSizing.resized(startFrame, edge: edge, dx: m.x - startMouse.x, dy: m.y - startMouse.y, within: area))
    }
    override func mouseUp(with e: NSEvent) { onEnd?() }
}

private struct PanelGrip: NSViewRepresentable {
    let edge: PanelEdge
    let model: AssistantModel
    func makeNSView(context: Context) -> PanelGripView {
        let v = PanelGripView()
        v.edge = edge
        v.onStart = { [weak model] in model?.panelResize(.begin) }
        v.onDrag = { [weak model] f in model?.panelResize(.frame(f)) }
        v.onEnd = { [weak model] in model?.panelResize(.end) }
        return v
    }
    func updateNSView(_ v: PanelGripView, context: Context) {}
}

/// Invisible grips just inside the bar or the chat card, so the panel keeps its look: no frame, no outline.
struct PanelGrips: View {
    let model: AssistantModel
    let edges: Set<PanelEdge>
    /// The bar is a capsule, so its grips stay clear of the round ends, where there's nothing to catch a click.
    var capsule = false
    private let side: CGFloat = 5, corner: CGFloat = 16

    var body: some View {
        let endGap: CGFloat = capsule ? 24 : 18
        Color.clear.allowsHitTesting(false)
            .overlay(alignment: .top) { if edges.contains(.top) { grip(.top).frame(height: side).padding(.horizontal, endGap) } }
            .overlay(alignment: .bottom) { if edges.contains(.bottom) { grip(.bottom).frame(height: side).padding(.horizontal, endGap) } }
            .overlay(alignment: .leading) { if edges.contains(.left) { grip(.left).frame(width: side).padding(.vertical, capsule ? 12 : endGap) } }
            .overlay(alignment: .trailing) { if edges.contains(.right) { grip(.right).frame(width: side).padding(.vertical, capsule ? 12 : endGap) } }
            .overlay(alignment: .topLeading) { if edges.contains(.topLeft) { grip(.topLeft).frame(width: corner, height: corner).padding(capsule ? 8 : 0) } }
            .overlay(alignment: .topTrailing) { if edges.contains(.topRight) { grip(.topRight).frame(width: corner, height: corner).padding(capsule ? 8 : 0) } }
            .overlay(alignment: .bottomLeading) { if edges.contains(.bottomLeft) { grip(.bottomLeft).frame(width: corner, height: corner).padding(3) } }
            .overlay(alignment: .bottomTrailing) { if edges.contains(.bottomRight) { grip(.bottomRight).frame(width: corner, height: corner).padding(3) } }
    }

    private func grip(_ e: PanelEdge) -> some View { PanelGrip(edge: e, model: model) }
}
