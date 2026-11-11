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
        self.support = support
        reloadRulesIfChanged()
    }

    // MARK: - Simple AI rules

    private var support: URL!
    /// Your own rules (edit from the 混 menu). They win over the built-in ones.
    var myRulesFile: URL { support.appendingPathComponent("my-fixes.txt") }
    /// Rule packs downloaded by a future online update go here (*.txt).
    var updatesDir: URL { support.appendingPathComponent("updates", isDirectory: true) }
    private var rulesStamp = ""

    private var ruleFiles: [URL] {
        var files: [URL] = []
        if let built = Bundle.main.url(forResource: "rules", withExtension: "txt") { files.append(built) }
        let updates = (try? FileManager.default.contentsOfDirectory(at: updatesDir, includingPropertiesForKeys: nil)) ?? []
        files += updates.filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        files.append(myRulesFile)
        return files
    }

    /// Loads the rules again when a rule file was added or edited (cheap: compares dates).
    func reloadRulesIfChanged() {
        guard let engine = engine else { return }
        let files = ruleFiles
        let stamp = files.map { url -> String in
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return "\(url.lastPathComponent)@\(d?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
        guard stamp != rulesStamp else { return }
        rulesStamp = stamp
        engine.rules.load(files)
        engine.rulesChanged()
    }

    /// Opens your own rules file (creating it with a short guide the first time).
    func openMyRules() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: myRulesFile.path) {
            try? fm.createDirectory(at: support, withIntermediateDirectories: true)
            let guide = """
            # My fixes for MixKey — one per line:   what I type => what I mean
            # Save this file; MixKey picks the changes up the next time you start typing.
            # Examples (remove the # to use them):
            # tmr => tomorrow
            # pd => Port Dickson
            # could of => could have

            """
            try? guide.write(to: myRulesFile, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(myRulesFile)
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
