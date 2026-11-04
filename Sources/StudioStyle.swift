// The editor's look: light like the rest of Mercury or a dark studio, lit by the Mercury theme's colours.
// Soft rounded cards with a fine light edge, gradients and gentle glows on what's picked, springy
// hovers and presses. Everything in the editor draws with these.

import AppKit
import SwiftUI

enum SC {
    private static func c(_ hex: String, _ a: Double = 1) -> Color { Color(nsColor: NSColor(hex: hex, alpha: a)) }
    /// Light like the rest of Mercury, or a dark studio; the editor picks it (Auto follows the Mac).
    nonisolated(unsafe) static var dark = false
    static var bg: Color { dark ? c("0A0B0F") : c("F3F2EE") }
    static var panel: Color { dark ? c("111318") : c("FBFAF8") }
    static var raised: Color { dark ? c("171A21") : c("F1EFEB") }
    static var card: Color { dark ? c("1B1F27") : c("FFFFFF") }
    static var hover: Color { dark ? c("242934") : c("EAE8E3") }
    static var line: Color { dark ? Color.white.opacity(0.07) : Color.black.opacity(0.08) }
    static var lineStrong: Color { dark ? Color.white.opacity(0.13) : Color.black.opacity(0.14) }
    static var text: Color { dark ? Color.white.opacity(0.94) : c("16171B") }
    static var dim: Color { dark ? Color.white.opacity(0.6) : Color.black.opacity(0.56) }
    static var faint: Color { dark ? Color.white.opacity(0.34) : Color.black.opacity(0.36) }
    /// A see-through tint for quiet fills and marks: light on dark, dark on light.
    static func wash(_ a: Double) -> Color { dark ? Color.white.opacity(a) : Color.black.opacity(a * 0.7) }
    static func washText(_ a: Double) -> Color { dark ? Color.white.opacity(a) : Color.black.opacity(min(1, a * 1.25)) }
    static var shadow: Color { dark ? Color.black.opacity(0.6) : Color.black.opacity(0.14) }

    /// The theme's two colours, kept bright enough to glow on dark (Graphite borrows Violet's).
    static var ends: (NSColor, NSColor) {
        let t = ThemeStore.shared.current
        return t.id == "graphite" ? (NSColor(hex: "7B3FFF"), NSColor(hex: "D04BFF")) : (t.start, t.end)
    }
    static var accent: Color { Color(nsColor: ends.0.blended(withFraction: 0.4, of: ends.1) ?? ends.0) }
    static var nsAccent: NSColor { ends.0.blended(withFraction: 0.4, of: ends.1) ?? ends.0 }
    static var gradient: LinearGradient { LinearGradient(colors: [Color(nsColor: ends.0), Color(nsColor: ends.1)], startPoint: .topLeading, endPoint: .bottomTrailing) }
    static var edge: LinearGradient {
        dark ? LinearGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom)
             : LinearGradient(colors: [Color.black.opacity(0.07), Color.black.opacity(0.1)], startPoint: .top, endPoint: .bottom)
    }

    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.82)
}

extension View {
    /// A raised card with a fine light edge along the top.
    func studioCard(_ radius: CGFloat = 16, fill: Color = SC.card) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(SC.edge, lineWidth: 1))
    }

    /// A soft coloured glow for whatever's picked.
    func glow(_ on: Bool, radius: CGFloat = 10) -> some View {
        shadow(color: on ? SC.accent.opacity(0.45) : .clear, radius: radius)
    }
}

/// Grows a touch under the pointer and sinks when pressed.
struct Springy: ButtonStyle {
    var hoverScale: CGFloat = 1.03
    func makeBody(configuration: Configuration) -> some View { SpringyBody(configuration: configuration, hoverScale: hoverScale) }
    private struct SpringyBody: View {
        let configuration: Configuration
        let hoverScale: CGFloat
        @State private var hover = false
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.96 : (hover ? hoverScale : 1))
                .brightness(hover ? 0.04 : 0)
                .animation(SC.spring, value: hover)
                .animation(SC.spring, value: configuration.isPressed)
                .onHover { hover = $0 }
        }
    }
}

/// The main action: the theme gradient with a glow and a light sweep on hover.
struct GlowButton: View {
    let title: String
    var icon: String?
    var height: CGFloat = 34
    var full = false
    let action: () -> Void
    @State private var hover = false
    @State private var sweep = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .bold)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18).frame(height: height)
            .frame(maxWidth: full ? .infinity : nil)
            .background(
                ZStack {
                    Capsule().fill(SC.gradient)
                    // A band of light that crosses the button on hover.
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.45)
                            .offset(x: sweep ? g.size.width * 1.2 : -g.size.width * 0.6)
                    }
                    .clipShape(Capsule())
                }
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .shadow(color: SC.accent.opacity(hover ? 0.6 : 0.35), radius: hover ? 14 : 9, y: 3)
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(Springy(hoverScale: 1.02))
        .onHover { h in
            hover = h
            if h { sweep = false; withAnimation(.easeInOut(duration: 0.7)) { sweep = true } }
        }
    }
}

/// A quiet action on a raised capsule.
struct GhostButton: View {
    let title: String
    var icon: String?
    var full = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11.5, weight: .semibold)) }
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .foregroundStyle(SC.text.opacity(enabled ? 1 : 0.4))
            .padding(.horizontal, full ? 6 : 12).frame(height: 32)
            .frame(maxWidth: full ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SC.raised))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SC.line, lineWidth: 1))
        }
        .buttonStyle(Springy())
    }
}

/// A slider drawn as a soft track with a gradient fill and a glowing knob.
struct StudioSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onBegin: () -> Void = {}
    @State private var dragging = false
    @State private var hover = false
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let f = CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / max(0.0001, range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                Capsule().fill(SC.wash(0.09)).frame(height: 4)
                Capsule().fill(SC.gradient).frame(width: max(4, f * w), height: 4)
                Circle().fill(Color.white)
                    .frame(width: dragging ? 16 : (hover ? 14 : 12), height: dragging ? 16 : (hover ? 14 : 12))
                    .shadow(color: SC.accent.opacity(0.7), radius: dragging ? 8 : 4)
                    .offset(x: f * (w - 12) - (dragging ? 2 : (hover ? 1 : 0)))
                    .animation(SC.spring, value: dragging)
                    .animation(SC.spring, value: hover)
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !dragging { dragging = true; onBegin() }
                    let k = min(1, max(0, v.location.x / max(1, w)))
                    value = range.lowerBound + Double(k) * (range.upperBound - range.lowerBound)
                }
                .onEnded { _ in dragging = false })
        }
        .frame(height: 18)
    }
}
