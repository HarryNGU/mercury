// The editor's Canvas and Colour panels: the shape and background of the video, and its colour filters.

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Canvas

struct CanvasPanel: View {
    @ObservedObject var ed: ReelEditor
    var body: some View {
        PanelTitle(title: "Canvas", subtitle: "The shape of the video and what's around the recording.", icon: "aspectratio")
        PanelSection(title: "Shape") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(ReelSize.allCases) { s in
                    Button { ed.size = s } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(s.ratio, systemImage: s.icon).font(.system(size: 12.5, weight: .semibold))
                            Text(s.use).font(.system(size: 10.5)).foregroundStyle(ed.size == s ? Color.white.opacity(0.8) : SC.dim).lineLimit(1)
                        }
                        .foregroundStyle(ed.size == s ? Color.white : SC.text)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(ed.size == s ? AnyShapeStyle(SC.gradient) : AnyShapeStyle(SC.wash(0.05))))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(ed.size == s ? Color.white.opacity(0.2) : SC.line))
                        .glow(ed.size == s, radius: 8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        PanelSection(title: "Layout") {
            Chips(options: [("fit", "Fit"), ("fill", "Fill"), ("framed", "Framed")], selection: ed.bind(\.canvas.layout))
            Text(ed.plan.canvas.layout == "fit" ? "The whole recording, with the background around it." :
                 ed.plan.canvas.layout == "fill" ? "Fills the frame; the edges are cropped." : "A floating window with rounded corners and a shadow.")
                .font(.system(size: 11.5)).foregroundStyle(SC.dim)
            if ed.plan.canvas.layout == "framed" {
                ValueSlider(label: "Padding", value: ed.bind(\.canvas.padding, undoable: false), range: 0...0.2, format: pct, reset: 0.06, onBegin: ed.beginChange)
                ValueSlider(label: "Corners", value: ed.bind(\.canvas.corner, undoable: false), range: 0...0.08, format: { "\(Int($0 * 1000))" }, reset: 0.03, onBegin: ed.beginChange)
            } else if ed.size != .original {
                ValueSlider(label: "Crop in", value: ed.bind(\.zoom, undoable: false), range: 1...3, format: { String(format: "%.2f×", $0) }, reset: 1, onBegin: ed.beginChange)
                if ed.plan.zoom > 1.01 || ed.plan.canvas.layout == "fill" {
                    ValueSlider(label: "Left ↔ right", value: ed.bind(\.focusX, undoable: false), range: 0...1, format: pct, reset: 0.5, onBegin: ed.beginChange)
                    ValueSlider(label: "Top ↕ bottom", value: ed.bind(\.focusY, undoable: false), range: 0...1, format: pct, reset: 0.5, onBegin: ed.beginChange)
                }
            }
        }
        PanelSection(title: "Background") {
            Chips(options: [("blur", "Blur"), ("color", "Colour"), ("gradient", "Gradient")], selection: ed.bind(\.canvas.background))
            if ed.plan.canvas.background != "blur" {
                Swatches(hex: ed.bind(\.canvas.color), colors: ["15151A", "FFFFFF", "F4F1EA", "1C2541", "0B3D2E", "3A0CA3", "FF6B35", "E63946", "2A9D8F", "FFB703"])
            }
            if ed.plan.canvas.background == "gradient" {
                Swatches(hex: ed.bind(\.canvas.color2), colors: ["5B4BDB", "FF6FB5", "00B4D8", "FFD60A", "30D158", "FF453A", "111111", "FFFFFF", "8338EC", "FB5607"])
            }
        }
    }
}

// MARK: - Colour

struct ColourPanel: View {
    @ObservedObject var ed: ReelEditor
    var body: some View {
        PanelTitle(title: "Colour", subtitle: "Make it pop, or fix a dull camera.", icon: "camera.filters")
        PanelSection(title: "Looks") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5) {
                look("Natural") { $0 = Look(fadeIn: $0.fadeIn, fadeOut: $0.fadeOut) }
                look("Vivid") { $0.saturation = 1.35; $0.contrast = 1.08; $0.warmth = 0; $0.brightness = 0; $0.vignette = 0 }
                look("Punchy") { $0.saturation = 1.15; $0.contrast = 1.2; $0.vignette = 0.35; $0.warmth = 0; $0.brightness = 0 }
                look("Warm") { $0.warmth = 0.4; $0.saturation = 1.1; $0.contrast = 1.02; $0.brightness = 0; $0.vignette = 0 }
                look("Cool") { $0.warmth = -0.4; $0.saturation = 1.05; $0.contrast = 1.04; $0.brightness = 0; $0.vignette = 0 }
                look("Mono") { $0.saturation = 0; $0.contrast = 1.12; $0.warmth = 0; $0.brightness = 0; $0.vignette = 0.2 }
            }
        }
        PanelSection(title: "Filters") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(StudioFilters.all, id: \.0) { f in
                    FilterTile(ed: ed, id: f.0, name: f.1)
                }
            }
        }
        PanelSection(title: "Adjust") {
            ValueSlider(label: "Brightness", value: ed.bind(\.look.brightness, undoable: false), range: -1...1, format: signed, reset: 0, onBegin: ed.beginChange)
            ValueSlider(label: "Contrast", value: ed.bind(\.look.contrast, undoable: false), range: 0.5...1.5, format: around1, reset: 1, onBegin: ed.beginChange)
            ValueSlider(label: "Saturation", value: ed.bind(\.look.saturation, undoable: false), range: 0...2, format: around1, reset: 1, onBegin: ed.beginChange)
            ValueSlider(label: "Warmth", value: ed.bind(\.look.warmth, undoable: false), range: -1...1, format: signed, reset: 0, onBegin: ed.beginChange)
            ValueSlider(label: "Vignette", value: ed.bind(\.look.vignette, undoable: false), range: 0...1, format: pct, reset: 0, onBegin: ed.beginChange)
        }
        PanelSection(title: "Start and end") {
            ValueSlider(label: "Fade from black", value: ed.bind(\.look.fadeIn, undoable: false), range: 0...3, format: secs, reset: 0, onBegin: ed.beginChange)
            ValueSlider(label: "Fade to black", value: ed.bind(\.look.fadeOut, undoable: false), range: 0...3, format: secs, reset: 0, onBegin: ed.beginChange)
        }
    }

    private func look(_ name: String, _ f: @escaping (inout Look) -> Void) -> some View {
        Button { ed.change { f(&$0.look) } } label: {
            Text(name).font(.system(size: 11.5, weight: .medium)).frame(maxWidth: .infinity).frame(height: 28)
                .foregroundStyle(SC.text)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SC.wash(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SC.line))
        }
        .buttonStyle(Springy())
    }
    private func signed(_ v: Double) -> String { String(format: "%+d", Int((v * 100).rounded())) }
    private func around1(_ v: Double) -> String { String(format: "%+d", Int(((v - 1) * 100).rounded())) }
}

/// A filter choice with a little preview of the recording through it.
struct FilterTile: View {
    @ObservedObject var ed: ReelEditor
    let id: String
    let name: String
    @State private var thumb: CGImage?
    var body: some View {
        let on = ed.plan.look.filter == id
        Button { ed.change { $0.look.filter = id } } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SC.wash(0.08))
                    if let thumb { Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                }
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(on ? AnyShapeStyle(SC.gradient) : AnyShapeStyle(SC.line), lineWidth: on ? 2 : 1))
                .glow(on, radius: 6)
                Text(name).font(.system(size: 10.5, weight: on ? .semibold : .medium)).foregroundStyle(on ? SC.text : SC.dim)
            }
        }
        .buttonStyle(Springy())
        .task {
            guard let frame = await StudioFrames.frame(ed.url, at: min(10, ed.originalLength / 2)) else { return }
            let img = StudioFilters.apply(id, to: CIImage(cgImage: frame))
            thumb = CIContext().createCGImage(img, from: CIImage(cgImage: frame).extent)
        }
    }
}
