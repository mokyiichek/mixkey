import Foundation

/// MixKey's "Simple AI": plain, local fix rules — no internet, no model.
///
/// Rules are text files, one rule per line: `what you typed => what you meant`.
///   dont => don't            (one word: fixed when you press space)
///   could of => could have   (two or three words: fixed together, even after the first word went out)
/// Lines starting with # are comments. Matching ignores capitals.
///
/// Several files can be loaded; later files win, so the order is: built-in rules, downloaded updates,
/// then your own rules.
public final class SimpleAI {
    private(set) var words: [String: String] = [:]
    private(set) var phrases: [String: String] = [:]
    public private(set) var maxPhraseWords = 1
    public private(set) var ruleCount = 0

    public init() {}

    public convenience init(files: [URL]) {
        self.init()
        load(files)
    }

    /// Replaces all rules with the ones in these files (missing files are skipped).
    public func load(_ files: [URL]) {
        words = [:]
        phrases = [:]
        maxPhraseWords = 1
        for url in files {
            if let text = try? String(contentsOf: url, encoding: .utf8) { add(text) }
        }
        ruleCount = words.count + phrases.count
    }

    /// Adds rules from text (same format as the files).
    public func add(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#"), let arrow = l.range(of: "=>") else { continue }
            let from = SimpleAI.normal(String(l[..<arrow.lowerBound]))
            let to = l[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty, !to.isEmpty else { continue }
            let n = from.split(separator: " ").count
            if n == 1 {
                words[from] = to
            } else {
                phrases[from] = to
                maxPhraseWords = max(maxPhraseWords, n)
            }
        }
        ruleCount = words.count + phrases.count
    }

    /// Fix for one word, or nil.
    public func word(_ w: String) -> String? { words[w.lowercased()] }

    /// Fix for several words together, or nil.
    public func phrase(_ ws: [String]) -> String? {
        guard ws.count >= 2 else { return nil }
        return phrases[SimpleAI.normal(ws.joined(separator: " "))]
    }

    static func normal(_ s: String) -> String {
        s.lowercased().split(separator: " ").joined(separator: " ")
    }
}
