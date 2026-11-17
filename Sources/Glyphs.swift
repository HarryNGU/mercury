// Mercury's own symbols, drawn on a 24-point grid around the app's circle-and-dot logo, so the
// main features look like one family instead of stock icons.

import SwiftUI

struct BubbleGlyph: View {
    enum Kind { case record, dictate, assist }
    let kind: Kind
    /// Two-tone (theme colours) on Home cards; one colour in the sidebar.
    var tinted = true
    var lineWidth: CGFloat = 1.9

    var body: some View {
        Canvas { ctx, size in
            let u = size.width / 24
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * u, y: y * u) }
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * u, y: y * u, width: w * u, height: h * u) }
            let ink = GraphicsContext.Shading.foreground
            let line = StrokeStyle(lineWidth: lineWidth * u, lineCap: .round, lineJoin: .round)
            let accent: GraphicsContext.Shading = tinted
                ? .linearGradient(Gradient(colors: [Color(nsColor: ThemeStore.shared.current.start), Color(nsColor: ThemeStore.shared.current.end)]),
                                  startPoint: p(2, 2), endPoint: p(22, 22))
                : ink
            let soft: GraphicsContext.Shading = tinted ? .color(Theme.accent.opacity(0.9)) : ink

            switch kind {
            case .record:
                // The screen, with your camera bubble sitting on its corner and a live dot.
                ctx.stroke(Path(roundedRect: r(3, 3.5, 18, 13.5), cornerRadius: 3.5 * u), with: soft, style: line)
                let bubble = Path(ellipseIn: r(2.5, 12, 9, 9))
                ctx.blendMode = .destinationOut
                ctx.fill(Path(ellipseIn: r(1.2, 10.7, 11.6, 11.6)), with: .color(.black))  // gap around the bubble
                ctx.blendMode = .normal
                ctx.fill(bubble, with: accent)
                if tinted { ctx.fill(Path(ellipseIn: r(5.6, 15.1, 2.8, 2.8)), with: .color(.white)) }  // the logo's dot
                ctx.fill(Path(ellipseIn: r(15.4, 6.6, 3.2, 3.2)), with: accent)

            case .dictate:
                // A speech bubble that's talking: a soundwave inside.
                var b = Path(roundedRect: r(2.5, 3, 19, 14), cornerRadius: 5 * u)
                b.move(to: p(7, 17)); b.addLine(to: p(5.5, 21)); b.addLine(to: p(11, 17))
                ctx.stroke(b, with: soft, style: line)
                for (x, h) in [(7.5, 3.0), (10.5, 7.0), (13.5, 5.0), (16.5, 2.4)] {
                    var bar = Path()
                    bar.move(to: p(x, 10 - h / 2)); bar.addLine(to: p(x, 10 + h / 2))
                    ctx.stroke(bar, with: accent, style: StrokeStyle(lineWidth: 2.1 * u, lineCap: .round))
                }

            case .assist:
                // Mercury's logo with a companion orbiting it: someone who knows you, always nearby.
                ctx.stroke(Path(ellipseIn: r(3, 5, 16, 16)), with: soft, style: line)
                ctx.fill(Path(ellipseIn: r(7.6, 9.6, 6.8, 6.8)), with: accent)
                ctx.blendMode = .destinationOut
                ctx.fill(Path(ellipseIn: r(14.3, 1.3, 8.4, 8.4)), with: .color(.black))  // clears the ring under the moon
                ctx.blendMode = .normal
                ctx.fill(Path(ellipseIn: r(15.6, 2.6, 5.8, 5.8)), with: accent)
            }
        }
        .compositingGroup()
        .accessibilityHidden(true)
    }
}

/// More of Mercury's own symbols, for settings: the same 24 point grid, round strokes and planet motifs as
/// BubbleGlyph, so nothing on these pages looks like a stock icon.
struct MercuryGlyph: View {
    enum Kind { case works, languages, suggest, balanced, goForIt, plus, close, chevrons }
    let kind: Kind
    /// Two tone in the theme's colours; otherwise one colour (the foreground style).
    var tinted = false
    var lineWidth: CGFloat = 2

    var body: some View {
        Canvas { ctx, size in
            let u = size.width / 24
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * u, y: y * u) }
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * u, y: y * u, width: w * u, height: h * u) }
            let ink = GraphicsContext.Shading.foreground
            let line = StrokeStyle(lineWidth: lineWidth * u, lineCap: .round, lineJoin: .round)
            let accent: GraphicsContext.Shading = tinted
                ? .linearGradient(Gradient(colors: [Color(nsColor: ThemeStore.shared.current.start), Color(nsColor: ThemeStore.shared.current.end)]),
                                  startPoint: p(2, 2), endPoint: p(22, 22))
                : ink
            let soft: GraphicsContext.Shading = tinted ? .color(Theme.accent.opacity(0.85)) : ink
            func cut(_ rect: CGRect) {
                ctx.blendMode = .destinationOut
                ctx.fill(Path(ellipseIn: rect), with: .color(.black))
                ctx.blendMode = .normal
            }

            switch kind {
            case .works:
                // A ringed planet with its moon: Mercury, working around you.
                var ring = Path(ellipseIn: r(1.5, 9.2, 21, 6.6))
                ring = ring.applying(CGAffineTransform(translationX: -12 * u, y: -12.5 * u)
                    .concatenating(CGAffineTransform(rotationAngle: -0.38))
                    .concatenating(CGAffineTransform(translationX: 12 * u, y: 12.5 * u)))
                ctx.stroke(ring, with: soft, style: line)
                cut(r(6.2, 6.7, 11.6, 11.6))
                ctx.fill(Path(ellipseIn: r(7.4, 7.9, 9.2, 9.2)), with: accent)
                ctx.fill(Path(ellipseIn: r(18, 2.6, 3.6, 3.6)), with: accent)

            case .languages:
                // Two speech bubbles, one over the other: two languages in one conversation.
                var back = Path(roundedRect: r(2, 2.5, 13, 10), cornerRadius: 4 * u)
                back.move(to: p(5.5, 12.5)); back.addLine(to: p(4.5, 15.5)); back.addLine(to: p(8.5, 12.5))
                ctx.stroke(back, with: soft, style: line)
                var front = Path(roundedRect: r(9, 8.5, 13, 10), cornerRadius: 4 * u)
                front.move(to: p(15.5, 18.5)); front.addLine(to: p(19.5, 21.5)); front.addLine(to: p(18.5, 18.5))
                ctx.blendMode = .destinationOut
                ctx.fill(Path(roundedRect: r(7.6, 7.1, 15.8, 12.8), cornerRadius: 5.2 * u), with: .color(.black))
                ctx.blendMode = .normal
                ctx.fill(front, with: accent)
                for x in [12.2, 15.5, 18.8] {
                    ctx.blendMode = .destinationOut
                    ctx.fill(Path(ellipseIn: r(x - 1, 12.5, 2, 2)), with: .color(.black))
                    ctx.blendMode = .normal
                }

            case .suggest:
                // A thought: Mercury shows you what it would do and waits.
                ctx.stroke(Path(ellipseIn: r(3, 2.5, 18, 14)), with: soft, style: line)
                ctx.fill(Path(ellipseIn: r(4.2, 17.6, 3.4, 3.4)), with: soft)
                ctx.fill(Path(ellipseIn: r(1.8, 20.6, 2, 2)), with: soft)
                for x in [8.0, 12.0, 16.0] { ctx.fill(Path(ellipseIn: r(x - 1.3, 8.2, 2.6, 2.6)), with: accent) }

            case .balanced:
                // The planet with its moon held in a steady orbit.
                ctx.stroke(Path(ellipseIn: r(2.5, 4.5, 17, 17)), with: soft, style: line)
                ctx.fill(Path(ellipseIn: r(7.5, 9.5, 7, 7)), with: accent)
                cut(r(14.2, 1.4, 8.6, 8.6))
                ctx.fill(Path(ellipseIn: r(15.6, 2.8, 5.8, 5.8)), with: accent)

            case .goForIt:
                // A comet: Mercury off and moving on its own. A bright head, three streaks behind it.
                for (x0, y0, x1, y1, w) in [(14.6, 9.4, 3.2, 20.8, 1.0), (12.4, 7.6, 5.6, 14.4, 0.8), (16.4, 11.6, 9.6, 18.4, 0.8)] {
                    var t = Path()
                    t.move(to: p(x0, y0)); t.addLine(to: p(x1, y1))
                    ctx.stroke(t, with: soft, style: StrokeStyle(lineWidth: lineWidth * w * u, lineCap: .round))
                }
                ctx.fill(Path(ellipseIn: r(13.6, 2.4, 8, 8)), with: accent)

            case .plus:
                var s = Path()
                s.move(to: p(12, 5)); s.addLine(to: p(12, 19)); s.move(to: p(5, 12)); s.addLine(to: p(19, 12))
                ctx.stroke(s, with: ink, style: StrokeStyle(lineWidth: 2.6 * u, lineCap: .round))

            case .close:
                var s = Path()
                s.move(to: p(7, 7)); s.addLine(to: p(17, 17)); s.move(to: p(17, 7)); s.addLine(to: p(7, 17))
                ctx.stroke(s, with: ink, style: StrokeStyle(lineWidth: 2.6 * u, lineCap: .round))

            case .chevrons:
                var s = Path()
                s.move(to: p(7.5, 9.5)); s.addLine(to: p(12, 5)); s.addLine(to: p(16.5, 9.5))
                s.move(to: p(7.5, 14.5)); s.addLine(to: p(12, 19)); s.addLine(to: p(16.5, 14.5))
                ctx.stroke(s, with: ink, style: StrokeStyle(lineWidth: 2.4 * u, lineCap: .round, lineJoin: .round))
            }
        }
        .compositingGroup()
        .accessibilityHidden(true)
    }
}
