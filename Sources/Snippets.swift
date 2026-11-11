// Snippets: say a trigger phrase while dictating ("email 3") and Mercury types the saved
// text instead. Stored only on this Mac in ~/Library/Application Support/Bubble/snippets.json
// (never in the app bundle or the source code).

import Foundation

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String
    var text: String
}

final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()

    @Published private(set) var snippets: [Snippet] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bubble", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("snippets.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = list
        }
    }

    func add(trigger: String, text: String) {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines), v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !v.isEmpty else { return }
        snippets.insert(Snippet(trigger: t, text: v), at: 0)
        save()
    }

    func update(_ s: Snippet) {
        guard let i = snippets.firstIndex(where: { $0.id == s.id }) else { return }
        snippets[i] = s
        save()
    }

    func delete(_ s: Snippet) {
        snippets.removeAll { $0.id == s.id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)  // only you can read it
    }

    /// Phrases to help speech recognition hear the triggers correctly.
    var triggers: [String] { snippets.map(\.trigger) }

    /// Replaces spoken triggers with their text. Matching ignores case and punctuation, and
    /// treats "3" and "three" as the same, so "Email three." still becomes your address.
    func expand(_ text: String) -> String { Self.expand(text, with: snippets) }

    /// One pass over what you said: every trigger is found in the original words, longer triggers
    /// win where two overlap, and text that was put in is never searched again. (Expanding one
    /// snippet after another let "github" fire inside an expanded "github.io" link.)
    static func expand(_ text: String, with snippets: [Snippet]) -> String {
        let ns = text as NSString
        var hits: [(range: NSRange, text: String)] = []
        for s in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            let words = s.trigger.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            guard !words.isEmpty else { continue }
            let pattern = "\\b" + words.map(Self.variants).joined(separator: "[\\s,.\\-]+") + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            where !hits.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) {
                hits.append((m.range, s.text))
            }
        }
        var out = text
        for h in hits.sorted(by: { $0.range.location > $1.range.location }) {
            if let r = Range(h.range, in: out) { out.replaceSubrange(r, with: h.text) }
        }
        return out
    }

    private static let numberWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                                      "eleven", "twelve"]

    private static func variants(_ word: String) -> String {
        if let n = Int(word), n < numberWords.count { return "(?:\(word)|\(numberWords[n]))" }
        if let n = numberWords.firstIndex(of: word) { return "(?:\(word)|\(n))" }
        return NSRegularExpression.escapedPattern(for: word)
    }
}
