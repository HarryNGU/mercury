// The drill timer: an optional stopwatch beside the Ask Mercury input, for timing practice problems.
// It lives in the tools button inside the text box and only ever starts when you click it, or press
// its key if you've switched keys on (off by default).
// Laps go on the end of your next message ("laps: 41s, 63s; total 104s"), then it resets.
// If it never started, your message goes exactly as typed.

import SwiftUI

extension Settings {
    /// Whether the stopwatch keys are on (they only work while the panel is open).
    static var drillTimerOn: Bool {
        get { d.bool(forKey: "drillTimerOn") }
        set { d.set(newValue, forKey: "drillTimerOn") }
    }
    /// Seconds per problem before the display turns red. 0 means no target.
    static var drillTarget: Int {
        get { max(0, d.integer(forKey: "drillTarget")) }
        set { d.set(max(0, newValue), forKey: "drillTarget") }
    }
}

final class DrillTimer: ObservableObject {
    @Published private(set) var startedAt: Date?
    @Published private(set) var laps: [TimeInterval] = []
    private var lastSplit: Date?

    var running: Bool { startedAt != nil }

    func start() {
        guard startedAt == nil else { return }
        let now = Date()
        startedAt = now
        lastSplit = now
    }

    func lap() {
        guard let last = lastSplit else { return }
        let now = Date()
        laps.append(now.timeIntervalSince(last))
        lastSplit = now
    }

    /// Testing: a stopwatch on problem `laps.count + 1`, `split` seconds in.
    func fakeForTesting(laps: [TimeInterval], split: TimeInterval) {
        let now = Date()
        self.laps = laps
        lastSplit = now.addingTimeInterval(-split)
        startedAt = lastSplit!.addingTimeInterval(-laps.reduce(0, +))
    }

    func reset() {
        startedAt = nil
        lastSplit = nil
        laps = []
    }

    /// Time on the problem you're doing now.
    func split(at now: Date) -> TimeInterval { lastSplit.map { now.timeIntervalSince($0) } ?? 0 }
    func total(at now: Date) -> TimeInterval { startedAt.map { now.timeIntervalSince($0) } ?? 0 }

    /// The line for the end of a message, or nil if the stopwatch never started. Resets the stopwatch.
    /// With laps, the total is the laps added up, so time spent typing after the last lap isn't counted.
    func takeSummary(now: Date = Date()) -> String? {
        guard let start = startedAt else { return nil }
        let secs = laps.map { Int($0.rounded()) }
        let line = secs.isEmpty
            ? "total \(Int(now.timeIntervalSince(start).rounded()))s"
            : "laps: " + secs.map { "\($0)s" }.joined(separator: ", ") + "; total \(secs.reduce(0, +))s"
        reset()
        return line
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The running stopwatch, shown above the text while you type.
struct DrillStrip: View {
    @ObservedObject var timer: DrillTimer
    @AppStorage("drillTarget") private var target = 0
    @ObservedObject private var keys = ShortcutCenter.shared

    var body: some View {
        if timer.running { strip }
    }

    private var strip: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let split = timer.split(at: ctx.date)
            let over = target > 0 && split >= Double(target)
            HStack(spacing: 10) {
                Image(systemName: "stopwatch").font(.system(size: 11))
                    .foregroundStyle(over ? Color.red : .white.opacity(0.6))
                Text("P\(timer.laps.count + 1) \(DrillTimer.clock(split))")
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(over ? Color.red : .white.opacity(0.95))
                    .help(target > 0 ? "Target \(target)s a problem" : "This problem")
                Text(DrillTimer.clock(timer.total(at: ctx.date)))
                    .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                    .help("Total")
                // The latest laps; older ones still go in the message.
                let shown = Array(timer.laps.enumerated().suffix(4))
                HStack(spacing: 8) {
                    if timer.laps.count > shown.count { Text("…").foregroundStyle(.white.opacity(0.4)) }
                    ForEach(shown, id: \.offset) { i, t in
                        Text("P\(i + 1) \(Int(t.rounded()))s")
                            .foregroundStyle(target > 0 && t >= Double(target) ? Color.red.opacity(0.85) : .white.opacity(0.6))
                    }
                }
                .font(.system(size: 11.5).monospacedDigit()).lineLimit(1)
                Spacer(minLength: 0)
                Button(action: timer.lap) { Text("Lap").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.75))
                    .help("Lap (\(keys.label(.timerLap)))")
                Button(action: timer.reset) { Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
                    .help("Stop and reset (\(keys.label(.timerStop)))").accessibilityLabel("Stop and reset the stopwatch")
            }
        }
        .frame(height: 18)
    }
}

/// The tools button inside the text box, like the + in a messaging app. For now it holds the
/// stopwatch, with its quick settings; the rest are in Mercury's Assistant settings.
struct ChatToolsButton: View {
    @ObservedObject var timer: DrillTimer
    var onKeysChanged: () -> Void = {}
    @ObservedObject private var keys = ShortcutCenter.shared
    @AppStorage("drillTimerOn") private var keysOn = false
    @AppStorage("drillTarget") private var target = 0
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(open ? 1 : 0.7))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(open ? 0.22 : 0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help("Tools").accessibilityLabel("Tools")
        .panelPopover(isPresented: $open, arrowEdge: .top) { menu }
    }

    @State private var hoverStart = false
    @State private var hoverMore = false

    var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if timer.running { timer.reset() } else { timer.start() }
                open = false
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: timer.running ? "stop.circle.fill" : "stopwatch")
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.accent).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(timer.running ? "Stop and reset" : "Start stopwatch")
                            .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(PanelCard.text)
                        Text("Laps go on your next message")
                            .font(.system(size: 11.5)).foregroundStyle(PanelCard.subtle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(hoverStart ? 0.08 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { hoverStart = $0 }

            Rectangle().fill(PanelCard.line).frame(height: 1).padding(.vertical, 6).padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("Target a problem").font(.system(size: 12.5)).foregroundStyle(PanelCard.text)
                    Spacer()
                    HStack(spacing: 3) {
                        TextField("", text: Binding(
                            get: { target > 0 ? String(target) : "" },
                            set: { target = max(0, Int($0.filter(\.isNumber).prefix(5)) ?? 0) }),
                            prompt: Text("none").foregroundStyle(PanelCard.subtle))
                            .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                            .font(.system(size: 12.5).monospacedDigit()).foregroundStyle(PanelCard.text)
                        Text("s").font(.system(size: 12)).foregroundStyle(PanelCard.subtle)
                    }
                    .padding(.horizontal, 8).frame(width: 74, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(PanelCard.field))
                }
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use keys").font(.system(size: 12.5)).foregroundStyle(PanelCard.text)
                        Text("Start \(keys.label(.timerStart)), lap \(keys.label(.timerLap)), stop \(keys.label(.timerStop))")
                            .font(.system(size: 11.5)).foregroundStyle(PanelCard.subtle)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { keysOn }, set: { keysOn = $0; onKeysChanged() }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(Theme.accent)
                }
            }
            .padding(.horizontal, 10)

            Rectangle().fill(PanelCard.line).frame(height: 1).padding(.top, 10).padding(.bottom, 4).padding(.horizontal, 4)

            Button {
                open = false
                (NSApp.delegate as? AppDelegate)?.showPageNamed(Page.assistant.rawValue)
            } label: {
                HStack {
                    Text("More settings").font(.system(size: 12.5)).foregroundStyle(PanelCard.text.opacity(hoverMore ? 1 : 0.8))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(PanelCard.subtle)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(hoverMore ? 0.08 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { hoverMore = $0 }
        }
        .padding(6).frame(width: 290)
    }
}
