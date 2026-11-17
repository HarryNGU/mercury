import SwiftUI

// The part of Settings, Assistant where people shape Mercury for themselves: how hands on it is, their own
// rules, what it knows about them and the languages they speak. Built to feel like Mercury rather than a
// form: the planet, the brand gradient, cards with depth. Getting Mercury to know you is one click: Claude
// Code's memory where it exists, or your usual AI, whose answer Mercury picks up from the clipboard by itself
// when you come back. Mercury's safety rules aren't here on purpose: they're fixed in the code (Behaviour.swift).

struct BehaviourSettings: View {
    @State private var handsOn = HandsOn.current
    @State private var rules = MyRules.list
    @State private var newRule = ""
    @State private var writingRule = false
    @State private var spoken = Languages.spoken
    @State private var reply = Languages.reply

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            KnowYouCard()
            behaves
            languages
        }
    }

    // MARK: How Mercury behaves

    private var behaves: some View {
        MercuryCard {
            SectionTitle(glyph: .works, title: "How Mercury works for you",
                         subtitle: "It always asks before it sends, posts, buys or deletes anything.")
            HStack(spacing: 10) {
                ForEach(HandsOn.allCases) { level in
                    LevelTile(level: level, selected: handsOn == level) {
                        handsOn = level; Settings.d.set(level.rawValue, forKey: "handsOn")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Your rules").font(.system(size: 13, weight: .semibold))
                Flow(spacing: 8) {
                    ForEach(rules, id: \.self) { r in
                        Pill(text: r) { rules.removeAll { $0 == r }; MyRules.list = rules }
                    }
                    Menu {
                        ForEach(MyRules.presets, id: \.0) { group, picks in
                            Section(group) {
                                ForEach(picks.filter { !rules.contains($0) }, id: \.self) { r in Button(r) { add(rule: r) } }
                            }
                        }
                        Divider()
                        Button("Write my own…") { writingRule = true }
                    } label: { AddPill(title: rules.isEmpty ? "Add a rule" : "Add") }
                    .menuStyle(.button).buttonStyle(.chunkyBrand).menuIndicator(.hidden).fixedSize()
                }
                if writingRule {
                    HStack(spacing: 8) {
                        TextField("Like: never message my boss", text: $newRule).textFieldStyle(.plain)
                            .padding(.horizontal, 14).frame(height: 34)
                            .background(Capsule().fill(Palette.canvas))
                            .overlay(Capsule().strokeBorder(Chunk.rim, lineWidth: 2))
                            .onSubmit { add(rule: newRule); newRule = ""; writingRule = false }
                        BrandButton(title: "Add") { add(rule: newRule); newRule = ""; writingRule = false }
                    }
                }
            }
        }
    }

    private func add(rule: String) {
        let r = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty, !rules.contains(r) else { return }
        rules.append(r); MyRules.list = rules
    }

    // MARK: Languages

    private var languages: some View {
        MercuryCard(seed: 21) {
            SectionTitle(glyph: .languages, title: "Languages",
                         subtitle: "Talk or type in any of these, mixed if you like. English words stay English.")
            Flow(spacing: 8) {
                ForEach(spoken, id: \.self) { code in
                    Pill(text: Languages.name(code), strong: true) { spoken.removeAll { $0 == code }; savedSpoken() }
                }
                Menu {
                    ForEach(Languages.all.filter { !spoken.contains($0.0) }, id: \.0) { code, name in
                        Button(name) { spoken.append(code); savedSpoken() }
                    }
                } label: { AddPill(title: spoken.isEmpty ? "Add a language" : "Add") }
                .menuStyle(.button).buttonStyle(.chunkyBrand).menuIndicator(.hidden).fixedSize()
            }
            HStack {
                Text("Mercury replies in").font(.system(size: 13, weight: .medium))
                Spacer()
                Menu {
                    Button("The language I use") { reply = "same"; Languages.reply = reply }
                    Divider()
                    ForEach(Languages.all, id: \.0) { code, name in Button(name) { reply = code; Languages.reply = reply } }
                } label: { RaisedSelect(title: reply == "same" ? "The language I use" : Languages.name(reply)) }
                .menuStyle(.button).buttonStyle(.chunky).menuIndicator(.hidden).fixedSize()
            }
        }
    }

    private func savedSpoken() {
        Languages.spoken = spoken
        WhisperServer.shared.stop()   // it restarts with the new language the next time you talk
    }
}

// MARK: - Getting to know you

/// One card, one main action. Claude Code's memory when it's on this Mac (one click), otherwise your usual AI:
/// Mercury opens it with the question ready and, when you copy its answer and come back, takes it in by itself.
struct KnowYouCard: View {
    @State private var facts = AboutMe.facts
    @State private var useClaude = ClaudeMemory.allowed
    @State private var waitingFor: String?
    @State private var startCount = 0
    @State private var note: String?
    @State private var showFacts = false
    @State private var newFact = ""
    private let tick = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()

    private var known: Int { facts.count + (useClaude ? 1 : 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            if showFacts { factList }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.08)))
        .shadow(color: Color(red: 0.1, green: 0.2, blue: 0.6).opacity(0.25), radius: 18, y: 8)
        .onReceive(tick) { _ in pickUpAnswer() }
    }

    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [Color(red: 0.03, green: 0.06, blue: 0.16), Color(red: 0.09, green: 0.16, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let planet = Brand.planet {
                Image(nsImage: planet).resizable().frame(width: 170, height: 170)
                    .offset(x: 40, y: -36).opacity(0.9)
                    .shadow(color: Color(red: 0.3, green: 0.5, blue: 1).opacity(0.5), radius: 30)
            }
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(known == 0 ? "Let Mercury get to know you" : "Mercury knows you")
                        .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    Text(status).font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 430, alignment: .leading)
                }
                actions
                HStack(spacing: 14) {
                    HStack(spacing: 6) { MercuryGlyph(kind: .suggest).frame(width: 12, height: 12); Text("Learns as you chat") }
                    if known > 0 {
                        Button { withAnimation(.easeOut(duration: 0.2)) { showFacts.toggle() } } label: {
                            Text(showFacts ? "Hide what it knows" : "See what it knows").underline(true, color: .white.opacity(0.3))
                        }.buttonStyle(.plain)
                    } else {
                        Button { withAnimation(.easeOut(duration: 0.2)) { showFacts = true } } label: { Text("Or tell it yourself") }
                            .buttonStyle(.plain)
                    }
                }
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 196)
    }

    private var status: String {
        if let note { return note }
        if let w = waitingFor { return "In \(w), press Enter, then copy its answer and come back. Mercury takes it from there." }
        if known == 0 { return "One click, and Mercury knows who you are, what you're working on and how you like help. Saved only on this Mac." }
        var parts: [String] = []
        if useClaude { parts.append("Claude's memory") }
        if !facts.isEmpty { parts.append("\(facts.count) thing\(facts.count == 1 ? "" : "s") you shared") }
        return "Using " + parts.joined(separator: " and ") + ". Saved only on this Mac."
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if ClaudeMemory.available && !useClaude {
                HeroButton(title: "Use what Claude knows", icon: .balanced, primary: true) { connectClaude() }
            }
            ForEach(AIImport.sources.filter { !(ClaudeMemory.available && $0.id == "claude") }) { s in
                HeroButton(title: s.name, icon: nil, primary: !ClaudeMemory.available && s.id == "chatgpt" && known == 0) { start(s) }
            }
        }
    }

    private var factList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if useClaude {
                FactRow(text: "Claude Code's notes about you", glyph: true) { useClaude = false; ClaudeMemory.allowed = false }
            }
            ForEach(facts, id: \.self) { f in
                FactRow(text: f, glyph: false) { facts.removeAll { $0 == f }; AboutMe.facts = facts }
            }
            HStack(spacing: 8) {
                TextField("Add something Mercury should know", text: $newFact).textFieldStyle(.plain)
                    .onSubmit(addFact)
                BrandButton(title: "Add", action: addFact).disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(Palette.card)
    }

    // MARK: Actions

    private func addFact() {
        AboutMe.remember(newFact); newFact = ""; facts = AboutMe.facts
    }

    private func connectClaude() {
        let a = NSAlert()
        a.messageText = "Let Mercury use what Claude knows about you?"
        a.informativeText = "Mercury reads Claude Code's notes on this Mac and sends them with your questions to the AI you chose. Turn it off any time."
        a.addButton(withTitle: "Allow")
        a.addButton(withTitle: "Not now")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        useClaude = true; ClaudeMemory.allowed = true
        note = "Done. Mercury now knows what Claude knows about you."
    }

    private func start(_ s: AIImport.Source) {
        AIImport.open(s)
        startCount = NSPasteboard.general.changeCount   // the prompt Mercury just copied
        waitingFor = s.name; note = nil
    }

    /// While waiting, watches the clipboard: the first new copy that looks like an answer is taken in.
    private func pickUpAnswer() {
        guard let source = waitingFor, NSPasteboard.general.changeCount != startCount else { return }
        startCount = NSPasteboard.general.changeCount
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•*# ").union(.whitespaces)) }
            .filter { $0.count > 3 && $0.count < 300 }
        guard lines.count >= 2, !text.contains("Please write down everything you remember about me") else { return }
        let before = AboutMe.facts.count
        for l in lines.prefix(40) { AboutMe.remember(l) }
        facts = AboutMe.facts
        waitingFor = nil
        note = "Got it. Mercury learned \(facts.count - before) things about you from \(source)."
        log("about me: picked up an answer from the clipboard")
    }
}

// MARK: - Pieces

/// A settings card in Mercury's style.
struct MercuryCard<Content: View>: View {
    var seed: UInt64 = 0
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) { content }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Palette.border))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }
}

/// Colours for the chunky controls, tuned for light and dark.
enum Chunk {
    static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    /// Neutral face, its outline and the lip under it.
    static let face = dyn(.white, NSColor(white: 0.2, alpha: 1))
    static let rim = dyn(NSColor(white: 0.88, alpha: 1), NSColor(white: 0.3, alpha: 1))
    static let lip = dyn(NSColor(white: 0.82, alpha: 1), NSColor(white: 0.08, alpha: 1))
    /// The theme colour, and a deeper shade of it for the lip.
    static var brandLip: Color {
        Color(nsColor: Theme.nsAccent.blended(withFraction: 0.38, of: .black) ?? Theme.nsAccent)
    }
    static var brandRim: Color {
        Color(nsColor: Theme.nsAccent.blended(withFraction: 0.18, of: .black) ?? Theme.nsAccent)
    }
}

/// A chunky 3D button, like a game's: a solid face sitting on a darker lip. Pressing pushes the face down
/// onto the lip, so it feels like a real key.
struct ChunkyStyle<S: InsettableShape>: ButtonStyle {
    let shape: S
    var face: AnyShapeStyle
    var rim: Color
    var lip: Color
    var depth: CGFloat = 4
    /// A see through colour laid over the face (the face stays solid, so the lip never shows through).
    var tint: Color = .clear
    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed ? depth : 0
        return configuration.label
            .background(shape.fill(tint))
            .background(shape.fill(face))
            .overlay(shape.strokeBorder(rim, lineWidth: 2))
            .offset(y: down)
            .background(shape.fill(lip).offset(y: depth))
            .padding(.bottom, depth)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ChunkyStyle<Capsule> {
    /// The main action: the theme colour on a deeper lip.
    static var chunkyBrand: ChunkyStyle<Capsule> {
        ChunkyStyle(shape: Capsule(), face: AnyShapeStyle(Theme.brand), rim: Chunk.brandRim.opacity(0.0), lip: Chunk.brandLip)
    }
    /// Everything else: a white (or dark grey) key with a grey lip.
    static var chunky: ChunkyStyle<Capsule> {
        ChunkyStyle(shape: Capsule(), face: AnyShapeStyle(Chunk.face), rim: Chunk.rim, lip: Chunk.lip)
    }
}

/// Presses in a little, for small controls inside a chunky one.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SectionTitle: View {
    let glyph: MercuryGlyph.Kind, title: String, subtitle: String
    var body: some View {
        HStack(spacing: 12) {
            MercuryGlyph(kind: glyph).foregroundStyle(Theme.onBrand).frame(width: 20, height: 20)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.brand))
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Chunk.brandLip).offset(y: 3))
                .padding(.bottom, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Palette.subtle)
            }
        }
    }
}

/// One of the three hands on levels, as a chunky card you press.
struct LevelTile: View {
    let level: HandsOn, selected: Bool, pick: () -> Void
    private var glyph: MercuryGlyph.Kind {
        switch level { case .suggest: .suggest; case .balanced: .balanced; case .goForIt: .goForIt }
    }
    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 8) {
                MercuryGlyph(kind: glyph, tinted: selected).foregroundStyle(Palette.subtle)
                    .frame(width: 26, height: 26)
                Text(level.title).font(.system(size: 13.5, weight: .bold)).foregroundStyle(selected ? Theme.accent : Palette.ink)
                Text(level.summary).font(.system(size: 11.5)).foregroundStyle(Palette.subtle)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(ChunkyStyle(shape: RoundedRectangle(cornerRadius: 16, style: .continuous),
                                 face: AnyShapeStyle(Chunk.face),
                                 rim: selected ? Theme.accent : Chunk.rim,
                                 lip: selected ? Chunk.brandLip : Chunk.lip, depth: 4,
                                 tint: selected ? Theme.accent.opacity(0.1) : .clear))
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

/// A rule or language you chose, with an x.
struct Pill: View {
    let text: String
    var strong = false
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Palette.ink).lineLimit(1)
            Button(action: remove) {
                MercuryGlyph(kind: .close).foregroundStyle(Palette.subtle).frame(width: 8, height: 8)
                    .frame(width: 18, height: 18).background(Circle().fill(Palette.subtle.opacity(0.12)))
            }
            .buttonStyle(PressStyle()).help("Remove")
        }
        .padding(.leading, 14).padding(.trailing, 7).frame(height: 32)
        .background(Capsule().fill(Chunk.face))
        .overlay(Capsule().strokeBorder(Chunk.rim, lineWidth: 2))
        .background(Capsule().fill(Chunk.lip).offset(y: 3))
        .padding(.bottom, 3)
    }
}

/// The label of an Add menu; the menu itself wears the chunky brand style.
struct AddPill: View {
    let title: String
    var body: some View {
        HStack(spacing: 7) {
            MercuryGlyph(kind: .plus).frame(width: 10, height: 10)
            Text(title).font(.system(size: 12.5, weight: .bold))
        }
        .foregroundStyle(Theme.onBrand)
        .padding(.horizontal, 15).frame(height: 32)
    }
}

/// The label of a select menu: the current choice and Mercury's up and down chevrons.
struct RaisedSelect: View {
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Palette.ink)
            MercuryGlyph(kind: .chevrons).foregroundStyle(Theme.accent).frame(width: 10, height: 10)
        }
        .padding(.leading, 15).padding(.trailing, 13).frame(height: 32)
    }
}

struct BrandButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.onBrand)
                .padding(.horizontal, 16).frame(height: 32)
        }
        .buttonStyle(.chunkyBrand)
    }
}

/// Buttons on the dark planet card: one white main action, the rest glass.
struct HeroButton: View {
    let title: String, icon: MercuryGlyph.Kind?, primary: Bool, action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { MercuryGlyph(kind: icon, lineWidth: 2.4).frame(width: 15, height: 15) }
                Text(title).font(.system(size: 13, weight: .bold)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(primary ? Color(red: 0.05, green: 0.08, blue: 0.2) : .white)
            .padding(.horizontal, 15).frame(height: 34)
        }
        .buttonStyle(ChunkyStyle(shape: Capsule(),
                                 face: AnyShapeStyle(primary ? Color.white : Color(red: 0.16, green: 0.22, blue: 0.45)),
                                 rim: primary ? .clear : .white.opacity(0.14),
                                 lip: primary ? Color(red: 0.62, green: 0.68, blue: 0.85) : Color(red: 0.04, green: 0.06, blue: 0.16),
                                 depth: 4))
    }
}

struct FactRow: View {
    let text: String, glyph: Bool, remove: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Group {
                    if glyph { MercuryGlyph(kind: .balanced, tinted: true).frame(width: 14, height: 14) }
                    else { Circle().fill(Theme.brand).frame(width: 5, height: 5) }
                }.frame(width: 14)
                Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(action: remove) { MercuryGlyph(kind: .close).frame(width: 8, height: 8).frame(width: 20, height: 20) }
                    .buttonStyle(PressStyle()).foregroundStyle(Palette.subtle).help("Forget this")
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            Divider().padding(.leading, 44)
        }
    }
}

/// Lays out pills left to right, wrapping onto new lines.
struct Flow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}

/// In a chat: something about you the AI offers to remember. Nothing is saved until you press Remember.
struct RememberChip: View {
    let fact: String
    @State private var state = 0   // 0 asking, 1 saved, 2 skipped

    var body: some View {
        HStack(spacing: 8) {
            MercuryGlyph(kind: .balanced, tinted: state == 1).foregroundStyle(.white.opacity(0.7)).frame(width: 14, height: 14)
            Text(state == 1 ? "Remembered: \(fact)" : state == 2 ? "Not saved" : "Remember this? \(fact)")
                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if state == 0 {
                Button("No") { state = 2 }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                Button("Remember") { AboutMe.remember(fact); state = 1 }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 10).frame(height: 24).background(Capsule().fill(.white))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.11)))
        .onAppear { if AboutMe.facts.contains(where: { $0.caseInsensitiveCompare(fact) == .orderedSame }) { state = 1 } }
    }
}
