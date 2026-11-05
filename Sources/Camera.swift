// The floating camera bubble. Frames come from AVCaptureVideoDataOutput; when a background
// effect is on, Vision's person segmentation cuts you out and Core Image swaps what's behind you.
// The cut is eased over a few frames so things Vision is unsure about (a chair) don't flicker, and
// "show things too" adds whatever you hold up to the camera.

import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

final class CameraBubble: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let panel: NSPanel
    private let container = CameraView()
    private let imageLayer = CALayer()
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(label: "bubble.camera", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    /// Masks are plain numbers, not colours: without colour matching, easing between frames stays exact.
    private let maskContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    private static let raw: [CIImageOption: Any] = [.colorSpace: NSNull()]
    private static let maskSide: CGFloat = 256
    private let segmentation: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()
    private let things = VNGenerateForegroundInstanceMaskRequest()
    private let badge = NSTextField(labelWithString: "")
    /// Double click on the bubble: switch between just you and you plus what you hold up.
    var onToggleThings: (() -> Void)?
    private var configured = false
    private var lastFrame = Date()  // camera queue only
    // Read on the camera queue, written on main; only ever replaced whole.
    private var background = Settings.background
    private var pixelSize: CGFloat = Settings.bubbleSize * 2
    private var showThings = Settings.showThings
    private var lastMask: CIImage?  // camera queue only: the eased mask from the previous frame
    private var lastThings: CIImage?  // camera queue only: what you're holding, from the last time Vision looked
    private var maskFrame = 0

    override init() {
        let size = Settings.bubbleSize
        panel = NSPanel(contentRect: NSRect(x: 40, y: 40, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        container.wantsLayer = true
        imageLayer.contentsGravity = .resizeAspectFill
        container.layer?.addSublayer(imageLayer)
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        badge.layer?.cornerRadius = 9
        badge.alphaValue = 0
        container.addSubview(badge)
        container.onDoubleClick = { [weak self] in self?.onToggleThings?() }
        panel.contentView = container
        applyStyle()
        layout(size: size)
    }

    private func layout(size: CGFloat) {
        container.frame = NSRect(x: 0, y: 0, width: size, height: size)
        imageLayer.frame = container.bounds
        badge.frame = NSRect(x: size / 2 - 66, y: size * 0.14, width: 132, height: 18)
        pixelSize = size * (panel.screen?.backingScaleFactor ?? 2)
        applyStyle()
        if configured { matchPreset() }
    }

    /// Battery: ask the camera for no more than the bubble shows. 480p covers bubbles up to
    /// 480 pixels across; only bigger ones need 720p.
    private func matchPreset() {
        let want: AVCaptureSession.Preset = pixelSize > 480 ? .hd1280x720 : .vga640x480
        let px = pixelSize
        frameQueue.async {
            guard self.session.sessionPreset != want, self.session.canSetSessionPreset(want) else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = want
            self.session.commitConfiguration()
            self.capFrameRate()
            log("camera: \(want == .vga640x480 ? "480p" : "720p") for a \(Int(px)) px bubble")
        }
    }

    /// 24 pictures a second is smooth for a face and saves a fifth of the work of 30.
    private func capFrameRate() {
        guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device,
              device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 24 && $0.maxFrameRate >= 24 }),
              (try? device.lockForConfiguration()) != nil else { return }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 24)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 24)
        device.unlockForConfiguration()
    }

    func refreshStyle() { applyStyle() }

    /// Round bubble with a ring in the theme colour, or no frame at all in "clear" mode.
    private func applyStyle() {
        let clear = background == .clear
        let size = container.bounds.width
        container.layer?.masksToBounds = !clear
        container.layer?.cornerRadius = clear ? 0 : size / 2
        container.layer?.borderWidth = clear ? 0 : 4
        container.layer?.borderColor = Theme.nsAccent.cgColor
        container.layer?.backgroundColor = clear ? NSColor.clear.cgColor : NSColor.black.cgColor
        panel.hasShadow = !clear
    }

    func setBackground(_ bg: CameraBackground) {
        Settings.background = bg
        frameQueue.async { self.background = bg; self.lastMask = nil; self.lastThings = nil }
        background = bg
        applyStyle()
    }

    func setShowThings(_ on: Bool) {
        Settings.showThings = on
        frameQueue.async { self.showThings = on; self.lastMask = nil; self.lastThings = nil }
        flash(on ? "Showing things too" : "Just you")
    }

    /// A short label on the bubble so you can see which mode you've switched to.
    private func flash(_ text: String) {
        guard panel.isVisible, background != .off else { return }
        badge.stringValue = text
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; badge.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.badge.stringValue == text else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self.badge.animator().alphaValue = 0 }
        }
    }

    func setSize(_ size: CGFloat) {
        Settings.bubbleSize = size
        var f = panel.frame
        f.origin.y += f.height - size
        f.size = NSSize(width: size, height: size)
        panel.setFrame(f, display: true)
        layout(size: size)
    }

    func show(on screen: NSScreen?) {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            log("camera access = \(ok)")
            DispatchQueue.main.async {
                guard ok else {
                    if CommandLine.arguments.contains(where: { $0.hasPrefix("--") && $0.hasSuffix("test") }) { return }  // test runs
                    return alert("Mercury needs camera access. Turn it on in System Settings → Privacy & Security → Camera.")
                }
                self.startSession()
                if let screen { self.moveOnto(screen, force: !screen.frame.intersects(self.panel.frame)) }
                self.panel.orderFrontRegardless()
            }
        }
    }

    func hide() {
        panel.orderOut(nil)
        frameQueue.async { self.session.stopRunning() }
    }

    func moveOnto(_ screen: NSScreen, force: Bool = false) {
        guard force || !screen.frame.intersects(panel.frame) else { return }
        panel.setFrameOrigin(NSPoint(x: screen.frame.minX + 40, y: screen.frame.minY + 40))
    }

    /// Keep the bubble inside the recorded region (bottom-left corner) if it isn't already.
    func keepInside(_ rect: NSRect) {
        guard panel.isVisible, !rect.contains(panel.frame) else { return }
        let size = panel.frame.width
        let inset = min(24, max(0, (rect.width - size) / 2))
        panel.setFrameOrigin(NSPoint(x: rect.minX + inset, y: rect.minY + min(24, max(0, (rect.height - size) / 2))))
    }

    private func startSession() {
        if !configured {
            configured = true
            session.beginConfiguration()
            session.sessionPreset = pixelSize > 480 ? .hd1280x720 : .vga640x480
            if let device = AVCaptureDevice.default(for: .video),
               let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frameQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
        }
        frameQueue.async {
            if !self.session.isRunning { self.lastFrame = Date(); self.session.startRunning(); self.capFrameRate() }
        }
    }

    /// Testing: stops the camera, as a sleeping Mac does.
    func stallForTesting() { frameQueue.async { self.session.stopRunning() } }

    /// Restarts the camera if it stopped sending pictures, for example after the Mac began to sleep
    /// and powered it off. Called a few times a second while recording.
    func reviveIfNeeded() {
        guard panel.isVisible, configured else { return }
        frameQueue.async {
            guard Date().timeIntervalSince(self.lastFrame) > 2 else { return }
            log("camera: no picture for 2 s, starting it again")
            self.session.stopRunning()
            self.lastFrame = Date()
            self.session.startRunning()
        }
    }

    // MARK: Frame processing (camera queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lastFrame = Date()
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var img = CIImage(cvPixelBuffer: px)

        // Centre square, mirrored like a mirror, scaled to the bubble's pixel size.
        let e = img.extent
        let side = min(e.width, e.height)
        img = img.cropped(to: CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side))
            .transformed(by: CGAffineTransform(translationX: -(e.midX - side / 2), y: -(e.midY - side / 2)))
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -side, y: 0))
        let s = pixelSize / side
        img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let rect = img.extent

        let bg = background
        if bg != .off, let mask = personMask(for: img) {
            let backdrop: CIImage
            switch bg {
            case .blur: backdrop = img.clampedToExtent().applyingGaussianBlur(sigma: 22).cropped(to: rect)
            case .grey: backdrop = CIImage(color: CIColor(red: 0.17, green: 0.17, blue: 0.19)).cropped(to: rect)
            default: backdrop = CIImage.empty()
            }
            let blend = CIFilter.blendWithMask()
            blend.inputImage = img
            blend.backgroundImage = backdrop
            blend.maskImage = mask
            img = blend.outputImage?.cropped(to: rect) ?? img
        }

        guard let cg = ciContext.createCGImage(img, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return }
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.imageLayer.contents = cg
            CATransaction.commit()
        }
    }

    /// How much of you (and, if asked, what you're holding) is in each pixel, from 0 to 1.
    private func personMask(for img: CIImage) -> CIImage? {
        // Battery: Vision is the expensive part, so it looks at every other frame and the frames
        // in between reuse the last mask (which is eased over frames anyway, so it looks the same).
        // Finding things you're holding is heavier still, so that runs on every third look.
        maskFrame &+= 1
        if maskFrame % 2 == 1, let last = lastMask { return finish(last, img) }
        let findThings = showThings && (lastThings == nil || maskFrame % 6 == 0)
        let handler = VNImageRequestHandler(ciImage: img, options: [:])
        guard (try? handler.perform(findThings ? [segmentation, things] : [segmentation])) != nil,
              let buf = segmentation.results?.first?.pixelBuffer else { return nil }
        let side = Self.maskSide
        var mask = Self.fit(CIImage(cvPixelBuffer: buf, options: Self.raw), side)
        if findThings {
            lastThings = (things.results?.first?.instanceMask).flatMap { labels in
                // Each object has its own number in the label map; any number above zero counts.
                let any = Self.fit(CIImage(cvPixelBuffer: labels, options: Self.raw), side)
                    .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 255, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 255, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 255, y: 0, z: 0, w: 0)])
                    .applyingFilter("CIColorClamp")
                let box = CGRect(x: 0, y: 0, width: side, height: side)
                return maskContext.createCGImage(any, from: box, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
                    .map { CIImage(cgImage: $0, options: Self.raw) }
            }
        }
        if showThings, let any = lastThings {
            mask = any.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        }
        // Things fade in over a few frames, so a chair Vision keeps changing its mind about can't
        // flick on and off. But anything that's now clearly background goes at once, or the room
        // would trail behind you like a shadow when you move.
        if let last = lastMask {
            let eased = Self.times(mask, 0.4).applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: Self.times(last, 0.6)])
            mask = eased.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: Self.times(mask, 3).applyingFilter("CIColorClamp")])
        }
        let box = CGRect(x: 0, y: 0, width: side, height: side)
        guard let kept = maskContext.createCGImage(mask, from: box, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else { return nil }
        lastMask = CIImage(cgImage: kept, options: Self.raw)
        return finish(lastMask!, img)
    }

    /// Leave out what's only there now and then, scale up to the frame and soften the edge slightly.
    private func finish(_ eased: CIImage, _ img: CIImage) -> CIImage {
        let k = img.extent.width / Self.maskSide
        return eased.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 2, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 2, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 2, w: 0),
                "inputBiasVector": CIVector(x: -0.5, y: -0.5, z: -0.5, w: 0)])
            .applyingFilter("CIColorClamp").clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
            .applyingGaussianBlur(sigma: 1.5).cropped(to: img.extent)
    }

    private static func fit(_ m: CIImage, _ side: CGFloat) -> CIImage {
        m.transformed(by: CGAffineTransform(scaleX: side / m.extent.width, y: side / m.extent.height))
    }

    private static func times(_ m: CIImage, _ a: CGFloat) -> CIImage {
        m.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0)])
    }
}

/// The bubble's view: drags the window like the background does, and reports double clicks.
private final class CameraView: NSView {
    var onDoubleClick: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }
}
