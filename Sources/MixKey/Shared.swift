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
        engine?.englishFixer = Shared.fixEnglish
    }

    /// Local (offline) spelling help from macOS:
    ///  - "dickson" -> "Dickson" (only valid when capitalised = a name)
    ///  - "recieve" -> "receive", "dfiifcuilteiy" -> "difficulty"
    /// Words that are valid Malay are left alone.
    static func fixEnglish(_ word: String) -> String? {
        let checker = NSSpellChecker.shared
        func valid(_ w: String, _ lang: String) -> Bool {
            checker.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        let lang = "en"
        let misspelled = !valid(word, lang)
        let cap = word.prefix(1).uppercased() + word.dropFirst()
        if misspelled && valid(cap, lang) { return cap }
        guard Settings.shared.autoFixSpelling, word.count >= 3 else { return nil }
        if checker.availableLanguages.contains("ms"), valid(word, "ms") { return nil }
        let range = NSRange(location: 0, length: (word as NSString).length)
        if let c = checker.correction(forWordRange: range, in: word, language: lang, inSpellDocumentWithTag: 0),
           c.lowercased() != word {
            return c
        }
        if misspelled, word.count >= 4,
           let g = checker.guesses(forWordRange: range, in: word, language: lang, inSpellDocumentWithTag: 0)?.first {
            return g
        }
        return nil
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
