import AppKit
import MixKeyCore

/// Objects shared by every input session (one per app/text field).
final class Shared {
    static let shared = Shared()

    let engine: MixEngine?
    let detector: ScriptDetector?
    let panel = CandidatePanel()
    var englishMode = false
    private var readingCache: [String: String] = [:]

    private init() {
        let path = Bundle.main.path(forResource: "mixkey", ofType: "db") ?? ""
        do {
            engine = try MixEngine(lexiconPath: path)
        } catch {
            NSLog("MixKey: failed to load lexicon: \(error)")
            engine = nil
        }
        detector = engine.map { ScriptDetector(converter: $0.script) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MixKey", isDirectory: true)
        engine?.lexicon.user = UserDictionary(url: support.appendingPathComponent("learned.json"))
        engine?.englishCapitalizer = Shared.capitalize
        engine?.englishGuesses = Shared.guesses
        engine?.keepWords = Set(UserDefaults.standard.stringArray(forKey: "keepWords") ?? [])
    }

    /// Never "fix" this word again (you pressed Delete right after it was changed).
    func keep(_ word: String) {
        guard let engine = engine, !engine.keepWords.contains(word) else { return }
        engine.keepWords.insert(word)
        UserDefaults.standard.set(Array(engine.keepWords).sorted(), forKey: "keepWords")
    }

    /// macOS spell checker helpers used by the engine's fixer.
    static let checker = NSSpellChecker.shared

    static func valid(_ w: String, _ lang: String) -> Bool {
        checker.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false,
                              inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }

    /// "dickson" -> "Dickson": only valid when capitalised, so it's a name.
    static func capitalize(_ word: String) -> String? {
        let cap = word.prefix(1).uppercased() + word.dropFirst()
        return !valid(word, "en") && valid(cap, "en") ? cap : nil
    }

    /// The system's autocorrection + guesses; nil = leave the word alone (valid English or Malay).
    static func guesses(_ word: String) -> (correction: String?, guesses: [String])? {
        if valid(word, "en") { return nil }
        if checker.availableLanguages.contains("ms"), valid(word, "ms") { return nil }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let corr = checker.correction(forWordRange: range, in: word, language: "en", inSpellDocumentWithTag: 0)
        let g = checker.guesses(forWordRange: range, in: word, language: "en", inSpellDocumentWithTag: 0) ?? []
        return (corr, Array(g.prefix(6)))
    }

    /// Pinyin with tone marks for Chinese text, e.g. 明天 -> míng tiān.
    func reading(_ text: String) -> String? {
        guard text.contains(where: ScriptConverter.isCJK), text.count <= 16 else { return nil }
        if let hit = readingCache[text] { return hit }
        let r = text.applyingTransform(.mandarinToLatin, reverse: false)
        if readingCache.count > 2000 { readingCache.removeAll() }
        readingCache[text] = r
        return r
    }
}
