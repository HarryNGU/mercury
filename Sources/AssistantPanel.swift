// The floating Ask Mercury window and the controller that shows, hides, moves and sizes it.
// The panel only takes the keyboard when you ask, so typing elsewhere is never interrupted.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import CryptoKit
import ScreenCaptureKit
import Speech
import SwiftUI
import WebKit

/// Where the chat is scrolled to, to tell your scrolling apart from new content arriving.
struct ScrollSpot: Equatable { var offset: CGFloat; var content: CGFloat; var visible: CGFloat }

/// Dragging here moves the window. Used for the panel's bar, so the chat below stays free for selecting text.
struct WindowDragHandle: NSViewRepresentable {
    final class Handle: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { Handle() }
    func updateNSView(_ view: NSView, context: Context) {}
}

final class AssistantPanel: NSPanel {
    /// While Claude drives other apps the panel can't take the keyboard at all.
    var keyboardLocked = false
    override var canBecomeKey: Bool { !keyboardLocked }
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        alwaysDark()
    }
    var onEscape: (() -> Void)?
    /// Gives up the keyboard without hiding. Taking the window off screen for an instant makes macOS pass key
    /// status back to the app in front; it comes straight back, unable to take the keyboard again.
    func handBackKeyboard() {
        guard isKeyWindow, isVisible else { return }
        let wasLocked = keyboardLocked
        keyboardLocked = true
        orderOut(nil)
        orderFrontRegardless()
        keyboardLocked = wasLocked
    }

    /// Esc closes an open picture, then cancels a reply, before it hides the panel.
    var onBack: (() -> Bool)?
    override func cancelOperation(_ sender: Any?) { if onBack?() != true { onEscape?() } }

    /// Return sends; Shift+Return (or Option+Return) starts a new line, as in Messages.
    override func sendEvent(_ event: NSEvent) {
        // Pinches go to the picture viewer wherever the pointer is, so one gesture can open a picture and keep zooming.
        if event.type == .magnify, PictureViewer.shared.pinch(amount: event.magnification, at: event.locationInWindow, windowHeight: contentView?.bounds.height ?? frame.height) { return }
        if event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
           !event.modifierFlags.intersection([.shift, .option]).isEmpty,
           let editor = firstResponder as? NSTextView {
            editor.insertNewlineIgnoringFieldEditor(nil)
            return
        }
        super.sendEvent(event)
    }
}

/// The bar and its answer card float at the top of the screen, see-through, like Cluely.
/// While they're up: ⌘ + arrows move them, ⌘⏎ asks about the screen, Esc hides.
@MainActor
final class AssistantController: NSObject, NSWindowDelegate {
    let model = AssistantModel()
    private var panel: AssistantPanel?
    private var top: CGFloat = 0          // the bar stays put while the card grows below it
    private var beforeFull: NSRect?       // where to go back to from Fill the Screen; zero means grow to fit
    private var cardWatch: AnyCancellable?
    private var fitWatch: AnyCancellable?
    private static let barOnly: CGFloat = 46
    var panelWindow: NSWindow? { panel }

    /// Stops the window following the conversation's size, so your size sticks.
    private func holdSize(_ size: CGSize) { model.panelSize = size }

    /// Left alone, the panel is exactly as tall as the conversation, with the bar staying put.
    private func followConversation(_ size: CGSize) {
        guard let p = panel, model.panelSize == nil, size.height > 40, p.frame.size != size else { return }
        if top > 0 { p.setFrame(NSRect(x: p.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true) }
        else { p.setContentSize(size) }
    }

    private func place(_ f: NSRect) {
        guard let p = panel else { return }
        holdSize(f.size)
        top = f.maxY
        let visible = model.cardOpen ? f : NSRect(x: f.minX, y: f.maxY - Self.barOnly, width: f.width, height: Self.barOnly)
        p.setFrame(visible, display: true)
    }

    private func remember() {
        if let s = model.panelSize { Settings.d.set([Double(s.width), Double(s.height)], forKey: "assistantSize") }
        else { Settings.d.removeObject(forKey: "assistantSize") }
    }

    private func growToFit() {
        model.panelFull = false
        beforeFull = nil
        model.panelSize = nil
        followConversation(model.fitSize)
        remember()
    }

    private func handle(_ r: AssistantModel.PanelResize) {
        guard let p = panel else { return }
        let area = (p.screen ?? NSScreen.underMouse).visibleFrame
        switch r {
        case .begin:
            if !model.cardOpen { model.cardOpen = true }
            holdSize(p.frame.size)
        case .frame(let f):
            model.panelFull = false
            place(f)
        case .end:
            remember()
        case .preset(let size):
            model.panelFull = false
            beforeFull = nil
            let s = PanelSizing.clamp(size, to: area)
            let x = min(area.maxX - s.width, max(area.minX, p.frame.minX))
            let t = max(area.minY + s.height, min(area.maxY, top))
            model.cardOpen = true
            place(NSRect(x: x, y: t - s.height, width: s.width, height: s.height))
            remember()
        case .full:
            if model.panelFull {
                model.panelFull = false
                if let b = beforeFull, b != .zero { place(b); beforeFull = nil; remember() } else { growToFit() }
            } else {
                beforeFull = model.panelSize == nil ? .zero : NSRect(x: p.frame.minX, y: top - model.panelSize!.height, width: model.panelSize!.width, height: model.panelSize!.height)
                model.cardOpen = true
                place(area)
                model.panelFull = true
                remember()
            }
        case .automatic:
            growToFit()
        }
    }

    /// Collapsing a panel you've sized folds it to the bar; expanding brings your size back.
    private func cardChanged(open: Bool) {
        guard let p = panel, let s = model.panelSize else { return }
        let h = open ? s.height : Self.barOnly
        p.setFrame(NSRect(x: p.frame.minX, y: top - h, width: s.width, height: h), display: true)
    }
    private static let keyIDs: [UInt32] = [20, 21, 22, 23, 24, 25, 26, 27]

    var isShown: Bool { panel?.isVisible == true }

    /// Called when the panel appears, hides, or its recordings-and-screen-shares setting changes.
    var onCaptureChange: (() -> Void)?
    private var shownInCaptures = Settings.showInCaptures

    /// The panel's windows a recording should include, when you've chosen to show it.
    var captureWindowNumbers: [Int] {
        guard Settings.showInCaptures, let p = panel, p.isVisible else { return [] }
        return [p.windowNumber] + (p.childWindows ?? []).map(\.windowNumber)
    }

    /// macOS leaves windows marked this way out of every screenshot, recording and screen share,
    /// whichever app takes it, so one switch covers Mercury's recordings and Zoom or Meet alike.
    private var sharing: NSWindow.SharingType { Settings.showInCaptures ? .readOnly : .none }

    private func applyCaptureVisibility() {
        panel?.sharingType = sharing
        panel?.childWindows?.forEach { $0.sharingType = sharing }
        onCaptureChange?()
    }

    @objc private func defaultsChanged() {
        guard Settings.showInCaptures != shownInCaptures else { return }
        shownInCaptures = Settings.showInCaptures
        log("assistant: \(shownInCaptures ? "shown in" : "hidden from") recordings and screen shares")
        applyCaptureVisibility()
    }

    /// Popovers (chat history, faces, the Listen card) are windows of their own: they follow the panel.
    @objc private func popoverShown(_ note: Notification) {
        guard let p = panel, p.isVisible, let w = (note.object as? NSPopover)?.contentViewController?.view.window,
              w.parent === p || p.isKeyWindow else { return }
        w.sharingType = sharing
    }

    /// Dictation (⌥⌥) while you're typing in the panel goes straight into its text box.
    func takeDictation(_ text: String) -> Bool {
        guard let p = panel, p.isVisible, p.isKeyWindow else { return false }
        let cur = model.input.trimmingCharacters(in: .whitespaces)
        model.input = cur.isEmpty ? text : cur + " " + text
        model.focusRequest += 1
        return true
    }

    func toggle() { isShown ? hide() : show() }

    func show() {
        guard Self.consent() else { return }
        let p = panel ?? makePanel()
        panel = p
        if !p.isVisible { model.freshenIfStale() }
        AppPresence.need("assistant", true)
        model.cardOpen = true
        p.sharingType = sharing
        if !p.isVisible {
            // Size to the content first, then pin the bar to the top centre of this screen.
            if let v = Settings.d.array(forKey: "assistantSize") as? [Double], v.count == 2 {
                let s = PanelSizing.clamp(CGSize(width: v[0], height: v[1]), to: NSScreen.underMouse.visibleFrame)
                holdSize(s)
                p.setContentSize(s)
            } else {
                p.contentViewController?.view.layoutSubtreeIfNeeded()
                p.setContentSize(model.fitSize.height > 40 ? model.fitSize : CGSize(width: 700, height: 460))
            }
            if let spot = savedSpot(width: p.frame.width) {
                // Back where you left it.
                top = spot.y
                p.setFrameOrigin(NSPoint(x: spot.x, y: top - p.frame.height))
            } else {
                let f = NSScreen.underMouse.visibleFrame
                top = f.maxY - 10
                p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: top - p.frame.height))
            }
            // A big saved size might not fit below where the panel was left.
            if let s = model.panelSize {
                let area = (p.screen ?? NSScreen.underMouse).visibleFrame
                let h = min(s.height, top - area.minY)
                if h >= PanelSizing.minimum.height, h != s.height { place(NSRect(x: p.frame.minX, y: top - h, width: s.width, height: h)) }
            }
        }
        // Shown, not focused: your keystrokes stay with the app you're in until you click the message box.
        p.orderFrontRegardless()
        model.warmUp()
        holdKeys()
        onCaptureChange?()
        log("assistant: shown")
    }

    /// Ask Mercury only runs after you've agreed to its ground rules (asked once).
    static func consent() -> Bool {
        if Settings.assistantConsent { return true }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Before you use Ask Mercury"
        a.informativeText = """
        • It sends one screenshot to your AI each time you ask (turn the eye off for private screens).
        • Listening is off until you turn it on. Other people on a call are transcribed too, so tell them.
        • Nothing is sent to anyone without your OK; messages are only typed in for you to send.
        • It asks before reading private files or opening links that carry data.
        • The chat shows up in recordings and screen shares unless you hide it. Don't use it to cheat or to record people secretly.
        """
        a.addButton(withTitle: "I agree")
        a.addButton(withTitle: "Not now")
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        Settings.assistantConsent = true
        return true
    }

    func hide() {
        ChatVideos.pause()
        MediaFullScreen.shared.close()
        panel?.orderOut(nil)
        ShortcutCenter.shared.releaseTemporary(Self.keyIDs)
        AppPresence.need("assistant", false)
        onCaptureChange?()
    }

    /// Re-registers the panel's keys (after you change them in settings).
    func refreshKeys() {
        guard isShown else { return }
        ShortcutCenter.shared.releaseTemporary(Self.keyIDs)
        holdKeys()
    }

    private func holdKeys() {
        let m = Settings.assistantMoveMods
        let ask = ShortcutCenter.shared[.assistAsk]
        ShortcutCenter.shared.holdTemporary([
            (20, kVK_LeftArrow, m, { [weak self] in self?.move(dx: -1, dy: 0, key: kVK_LeftArrow) }),
            (21, kVK_RightArrow, m, { [weak self] in self?.move(dx: 1, dy: 0, key: kVK_RightArrow) }),
            (22, kVK_UpArrow, m, { [weak self] in self?.move(dx: 0, dy: 1, key: kVK_UpArrow) }),
            (23, kVK_DownArrow, m, { [weak self] in self?.move(dx: 0, dy: -1, key: kVK_DownArrow) }),
            (24, Int(ask.keyCode), Int(ask.mods), { [weak self] in self?.quickAsk() }),
        ])
        // The drill timer's keys exist only while it's switched on and set to start with a key.
        if Settings.drillTimerOn {
            let c = ShortcutCenter.shared, drill = model.drill
            ShortcutCenter.shared.holdTemporary([
                (25, Int(c[.timerStart].keyCode), Int(c[.timerStart].mods), { drill.start() }),
                (26, Int(c[.timerLap].keyCode), Int(c[.timerLap].mods), { drill.lap() }),
                (27, Int(c[.timerStop].keyCode), Int(c[.timerStop].mods), { drill.reset() }),
            ])
        }
    }

    private var glide: Timer?

    /// A press moves the panel one step; holding the keys keeps it gliding until you let go.
    /// (Global shortcuts only report the press, so Mercury watches the arrow key itself.)
    private func move(dx: CGFloat, dy: CGFloat, key: Int) {
        nudge(dx: dx, dy: dy)
        glide?.invalidate()
        let pressed = Date()
        // Scheduled on the main run loop, so it fires on the main actor.
        glide = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.isShown, CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key)) else { t.invalidate(); return }
                if Date().timeIntervalSince(pressed) > 0.3 { self.nudge(dx: dx, dy: dy, step: 14) }
            }
        }
    }

    /// Puts the panel at a spot (left edge, top edge), for recording demos.
    func place(x: CGFloat, top newTop: CGFloat) {
        guard let p = panel else { return }
        top = newTop
        p.setFrameOrigin(NSPoint(x: x, y: newTop - p.frame.height))
    }

    private func nudge(dx: CGFloat, dy: CGFloat, step: CGFloat = 80) {
        guard let p = panel else { return }
        let screen = p.screen ?? NSScreen.underMouse
        let f = screen.visibleFrame
        var o = p.frame.origin
        o.x = min(f.maxX - p.frame.width, max(f.minX, o.x + dx * step))
        top = min(f.maxY, max(f.minY + 60, top + dy * step))
        o.y = top - p.frame.height
        p.setFrameOrigin(o)
    }

    /// ⌘⏎: ask about what's typed, or, with nothing typed, help with the screen right now.
    private func quickAsk() {
        let typed = model.input.trimmingCharacters(in: .whitespacesAndNewlines)
        model.cardOpen = true
        model.ask(typed.isEmpty ? (model.listening ? AssistantModel.sayPrompt : AssistantModel.screenPrompt) : nil)
    }

    func windowDidResize(_ n: Notification) {
        guard let p = panel, top > 0 else { return }
        p.setFrameOrigin(NSPoint(x: p.frame.minX, y: top - p.frame.height))
    }

    /// Dragging the bar moves the anchor with it.
    func windowDidMove(_ n: Notification) {
        guard let p = panel, p.isVisible, top > 0 else { return }
        top = p.frame.maxY
        Settings.d.set([p.frame.minX, top], forKey: "assistantSpot")  // reopen right here next time
    }

    /// Where you last left the panel (left edge, top edge), if that spot is still on a screen.
    private func savedSpot(width: CGFloat) -> NSPoint? {
        guard let v = Settings.d.array(forKey: "assistantSpot") as? [Double], v.count == 2 else { return nil }
        let spot = NSPoint(x: v[0], y: v[1])
        let probe = NSPoint(x: spot.x + width / 2, y: spot.y - 20)
        return NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -2, dy: -2).contains(probe) } ? spot : nil
    }

    private func makePanel() -> AssistantPanel {
        let p = AssistantPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 60),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false  // only the bar moves it, so you can select text in the chat
        p.becomesKeyOnlyIfNeeded = true   // only a click in the message box takes the keyboard
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.onEscape = { [weak self] in
            guard let self else { return }
            if self.model.talking { self.model.cancelTalk() } else { self.hide() }
        }
        p.onBack = { [weak self] in
            if PictureViewer.shared.closeIfOpen() { return true }
            if self?.model.replyingTo != nil { self?.model.replyingTo = nil; return true }
            return false
        }
        p.delegate = self
        p.sharingType = sharing
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(popoverShown), name: NSPopover.willShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(popoverShown), name: NSPopover.didShowNotification, object: nil)
        let host = NSHostingController(rootView: AssistantView(model: model, onClose: { [weak self] in self?.hide() }))
        host.sizingOptions = []   // Mercury sets the window's size itself, in both modes
        p.contentViewController = host
        model.panelResize = { [weak self] r in self?.handle(r) }
        model.focusInput = { [weak self, weak p] in
            guard let self, let p, !self.model.controllingMac else { return }
            p.makeKey()
            self.model.focusRequest += 1
        }
        model.onControllingChange = { [weak p] on in
            guard let p else { return }
            p.keyboardLocked = on
            if on { p.handBackKeyboard() }
            log("assistant: \(on ? "Claude is using the Mac, panel off the keyboard" : "panel can take the keyboard again")")
        }
        cardWatch = model.$cardOpen.dropFirst().removeDuplicates().sink { [weak self] open in
            DispatchQueue.main.async { self?.cardChanged(open: open) }
        }
        fitWatch = model.$fitSize.removeDuplicates().sink { [weak self] size in
            DispatchQueue.main.async { self?.followConversation(size) }
        }
        model.panelNumber = { [weak p] in p.map { [$0.windowNumber] } ?? [] }
        return p
    }
}

enum MoveKeys: Int, CaseIterable, Identifiable {
    case option, command, control, optionCommand
    var id: Int { rawValue }
    var label: String { switch self { case .option: "⌥"; case .command: "⌘"; case .control: "⌃"; case .optionCommand: "⌥⌘" } }
    var carbon: Int {
        switch self {
        case .option: optionKey
        case .command: cmdKey
        case .control: controlKey
        case .optionCommand: optionKey | cmdKey
        }
    }
}

extension Settings {
    /// Modifier held with the arrow keys to move Ask Mercury. Default ⌥.
    static var assistantMove: MoveKeys {
        get { MoveKeys(rawValue: d.integer(forKey: "assistantMove")) ?? .option }
        set { d.set(newValue.rawValue, forKey: "assistantMove") }
    }
    static var assistantMoveMods: Int { assistantMove.carbon }

    /// How dark the assistant's glass is: 0.25 (very see-through) to 0.85 (solid).
    static var assistantDarkness: Double {
        get { d.object(forKey: "assistantDarkness") as? Double ?? 0.62 }
        set { d.set(newValue, forKey: "assistantDarkness") }
    }
}
