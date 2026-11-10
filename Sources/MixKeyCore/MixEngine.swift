import Foundation

public struct Candidate: Equatable {
    public enum Kind: Equatable { case ai, smart, word, alternative, english }
    /// Text shown in the candidate window.
    public var display: String
    /// Text produced when this candidate is chosen (for words: everything before it + the word).
    public var output: String
    /// How many characters of the raw buffer this candidate uses up.
    public var consumes: Int
    public var kind: Kind
    /// Pinyin reading, shown under Chinese candidates.
    public var reading: String?

    public init(display: String, output: String, consumes: Int, kind: Kind, reading: String? = nil) {
        self.display = display
        self.output = output
        self.consumes = consumes
        self.kind = kind
        self.reading = reading
    }
}

public struct EngineOptions {
    /// Put a space between Chinese and English, e.g. "我要去 Port Dickson".
    public var spaceBetweenScripts = true
    /// Capitalise the first English word (start of a sentence).
    public var capitalizeFirst = false
    public init() {}
}

public struct Token: Equatable {
    public enum Kind: Equatable { case chinese, english }
    public let text: String
    public let start: Int
    public let end: Int
    public var kind: Kind
    /// Could reasonably be either pinyin or an English word ("you", "can", "long").
    public var ambiguous: Bool
}

/// A piece of the converted text that maps to a stretch of what was typed.
/// Chinese runs are one segment; English is one segment per word (or per multi-word name).
public struct Segment: Equatable {
    public let kind: Token.Kind
    public let start: Int
    public let end: Int
    public let output: String
    /// Pinyin key for Chinese segments ("ming tian").
    public var reading: String? = nil
}

public struct Analysis {
    public let raw: String
    public var segments: [Segment] = []
    public let tokens: [Token]
    /// Best guess for the whole buffer.
    public let preview: String
    public let previewReading: String?
    public let candidates: [Candidate]
    public var hasChinese: Bool { tokens.contains { $0.kind == .chinese } }
    public var endsWithChinese: Bool { tokens.last?.kind == .chinese }
}

/// Turns what the user typed ("wo ming tian qu port dickson") into mixed text ("我明天去 Port Dickson").
public final class MixEngine {
    public let lexicon: Lexicon
    public let pinyin: PinyinConverter
    public let script: ScriptConverter

    /// Capitalises names the frequency list doesn't know ("dickson" -> "Dickson"), e.g. via NSSpellChecker.
    public var englishCapitalizer: ((String) -> String?)?
    /// Extra spelling guesses for a word (e.g. NSSpellChecker). Return nil to leave the word alone
    /// (for example because it is valid Malay).
    public var englishGuesses: ((String) -> (correction: String?, guesses: [String])?)?
    public var fixSpelling = true
    public let speller: SpellFixer

    /// Remembers a choice. `picked` = chosen from the list; otherwise sent as typed.
    public func learn(reading: String, word: String, picked: Bool) {
        guard let user = lexicon.user, word.allSatisfy({ ScriptConverter.isCJK($0) }) else { return }
        // Whole phrase for the reading, e.g. "ming tian" -> 明天
        guard reading.split(separator: " ").count == word.count else { return }
        user.learn(key: reading, word: word, picked: picked)
        lexicon.userChanged()
    }

    public init(lexiconPath: String) throws {
        lexicon = try Lexicon(path: lexiconPath)
        pinyin = PinyinConverter(lexicon: lexicon)
        script = ScriptConverter(lexicon: lexicon)
        speller = SpellFixer(lexicon: lexicon)
    }

    private var fixCache: [String: String?] = [:]

    /// Spelling fix for one complete lowercase English word, or nil to keep it (cached).
    public func fixWord(_ w: String) -> String? {
        let key = "\(fixSpelling ? 1 : 0)|\(w)"
        if let hit = fixCache[key] { return hit }
        let r = computeFix(w)
        if fixCache.count > 5000 { fixCache.removeAll() }
        fixCache[key] = r
        return r
    }

    private func computeFix(_ w: String) -> String? {
        guard w == w.lowercased(), w.count >= 2, !SpellFixer.protected.contains(w) else { return nil }
        let rank = lexicon.englishRank(w)
        if rank == nil, let cap = englishCapitalizer?(w) { return cap }
        guard fixSpelling else { return nil }
        if let r = rank, r <= 20000 { return nil } // a normal English word
        var extra: [String] = []
        var preferred: String?
        if let hook = englishGuesses {
            guard let g = hook(w) else { return nil } // e.g. valid Malay: leave it
            extra = g.guesses
            preferred = g.correction
        }
        // When the system has an opinion, a far-fetched guess of ours that it doesn't share is dropped,
        // and its own first guess is used when we find nothing close ("dfiifcuilteiy" -> "difficulty").
        let systemFallback: String? = extra.first.flatMap { g in
            g.first == w.first && abs(g.count - w.count) <= 4 && !g.contains(" ") ? g : nil
        }
        guard let fix = speller.best(for: w, extra: extra, preferred: preferred) else {
            return rank == nil ? systemFallback : nil
        }
        if englishGuesses != nil, fix.cost > 1.6, fix.word != preferred, !extra.contains(fix.word) {
            return rank == nil ? systemFallback : nil
        }
        if rank != nil {
            // rare but real word ("lal"): only swap for a much more common, very close word ("all")
            return fix.cost <= 1 && fix.rank <= 3000 ? fix.word : nil
        }
        return fix.word
    }

    // MARK: - Tokens

    func tokenize(_ raw: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var start = 0
        for (i, ch) in raw.enumerated() {
            if ch == " " {
                if !current.isEmpty { tokens.append(Token(text: current, start: start, end: i, kind: .english, ambiguous: false)) }
                current = ""
            } else {
                if current.isEmpty { start = i }
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(Token(text: current, start: start, end: raw.count, kind: .english, ambiguous: false)) }
        return tokens
    }

    /// Pinyin syllables that show up in English word lists only as noise ("ma", "de", "re").
    static let pinyinParticles: Set<String> = ["ma", "de", "re", "le", "na", "ta", "ne", "ba", "la", "ya", "ha", "wa", "da", "ge", "ni", "wo", "ai", "zai", "shi", "bu"]

    /// How "English" a token looks, from word frequency (0 = not English).
    func englishScore(_ word: String) -> Double {
        let w = word.lowercased()
        if MixEngine.pinyinParticles.contains(w) { return 0 }
        // an apostrophe inside pinyin ("xi'an") is a syllable separator, unless it's an English contraction
        if w.contains("'") && lexicon.englishRank(w) == nil { return 0 }
        if lexicon.properNoun(w) != nil { return 3 }
        guard let rank = lexicon.englishRank(w) else { return 0 }
        var s: Double
        switch rank {
        case ...300: s = 3
        case ...1000: s = 2
        case ...2500: s = 1.2
        case ...6000: s = 0.4
        default: s = 0
        }
        if w.count >= 5 && rank <= 20000 { s += 1 }
        return s
    }

    func classify(_ tokens: inout [Token], rawEndsWithSpace: Bool) {
        enum Lean { case chinese, english, ambiguous }
        let n = tokens.count
        var lean = Array(repeating: Lean.english, count: n)
        var eScore = Array(repeating: 0.0, count: n)
        var cScore = Array(repeating: 0.0, count: n)
        var reading = Array(repeating: "", count: n)

        for (i, t) in tokens.enumerated() {
            let isLast = i == n - 1 && !rawEndsWithSpace
            let hasUpper = t.text.contains { $0.isUppercase }
            let letters = t.text.filter { $0 != "'" }
            if hasUpper || letters.isEmpty || !letters.allSatisfy({ $0.isASCII && $0.isLetter }) { continue }
            guard pinyin.isPinyin(t.text, allowPartialEnd: isLast),
                  let r = pinyin.convert(t.text, allowPartialEnd: isLast) else { continue }
            reading[i] = r.reading
            let e = englishScore(t.text)
            if e == 0 { lean[i] = .chinese; continue }
            lean[i] = .ambiguous
            eScore[i] = e
            let syllables = r.reading.split(separator: " ").count
            if syllables == 1 {
                cScore[i] = 0.8
            } else if let first = r.words.first, first.rawLength >= t.text.count, first.reading == r.reading {
                // the whole token is one Chinese word ("nihao" 你好); trust it by how common that word is
                cScore[i] = min(3, max(0.5, log10(Double(first.weight) + 1) - 2))
            } else {
                cScore[i] = 0.3
            }
        }
        // Multi-word proper nouns ("kuala lumpur", "port dickson") are always English.
        var i = 0
        while i < n {
            var len = min(lexicon.maxProperWords, n - i)
            var hit = false
            while len >= 2 {
                let phrase = tokens[i..<(i + len)].map { $0.text.lowercased() }.joined(separator: " ")
                if lexicon.properNoun(phrase) != nil {
                    for j in i..<(i + len) { lean[j] = .english }
                    i += len
                    hit = true
                    break
                }
                len -= 1
            }
            if !hit { i += 1 }
        }
        // Cohesion: does this token form a real word with a pinyin neighbour? ("ming" + "tian" = 明天)
        func pairWeight(_ a: Int, _ b: Int) -> Int {
            guard !reading[a].isEmpty, !reading[b].isEmpty else { return 0 }
            return lexicon.lookup(reading[a] + " " + reading[b]).first?.weight ?? 0
        }
        for i in 0..<n where lean[i] == .ambiguous {
            for j in [i - 1, i + 1] where j >= 0 && j < n {
                let w = j < i ? pairWeight(j, i) : pairWeight(i, j)
                if w >= 10000 { cScore[i] += 2.5 } else if w >= 1000 { cScore[i] += 1 }
            }
        }
        // Decide, using neighbours as context (two passes so ambiguous neighbours count too).
        var decided: [Token.Kind?] = lean.map { $0 == .chinese ? .chinese : ($0 == .english ? .english : nil) }
        for pass in 0..<2 {
            var next = decided
            for i in 0..<n where lean[i] == .ambiguous {
                var e = eScore[i]
                var c = cScore[i]
                for j in [i - 1, i + 1] where j >= 0 && j < n {
                    let weight = lean[j] == .ambiguous ? 0.3 : 0.5
                    if pass == 0 && lean[j] == .ambiguous { continue }
                    switch decided[j] {
                    case .chinese: c += weight
                    case .english: e += weight
                    case nil: break
                    }
                }
                next[i] = e >= c ? .english : .chinese
            }
            decided = next
        }
        for i in 0..<n {
            tokens[i].kind = decided[i] ?? .english
            tokens[i].ambiguous = lean[i] == .ambiguous
        }
    }

    // MARK: - Runs

    struct Run {
        var kind: Token.Kind
        var tokens: [Token]
        var start: Int { tokens.first!.start }
        var end: Int { tokens.last!.end }
    }

    func runs(_ tokens: [Token]) -> [Run] {
        var out: [Run] = []
        for t in tokens {
            if var last = out.last, last.kind == t.kind {
                last.tokens.append(t)
                out[out.count - 1] = last
            } else {
                out.append(Run(kind: t.kind, tokens: [t]))
            }
        }
        return out
    }

    /// Fixes casing of an English run: proper nouns ("port dickson" -> "Port Dickson"), "i" -> "I".
    public func caseEnglish(_ words: [String], fix: Bool = true, lastComplete: Bool = true) -> [String] {
        caseEnglishGroups(words, fix: fix, lastComplete: lastComplete).map(\.text)
    }

    /// Like caseEnglish, but keeps multi-word names together: [(how many typed words, text)].
    public func caseEnglishGroups(_ words: [String], fix: Bool = true, lastComplete: Bool = true) -> [(count: Int, text: String)] {
        var out: [(count: Int, text: String)] = []
        var i = 0
        while i < words.count {
            var matched = false
            var n = min(lexicon.maxProperWords, words.count - i)
            while n >= 1 {
                let phrase = words[i..<(i + n)].joined(separator: " ")
                // only adjust words the user typed in lowercase
                if phrase == phrase.lowercased(), let proper = lexicon.properNoun(phrase) {
                    out.append((n, proper))
                    i += n
                    matched = true
                    break
                }
                n -= 1
            }
            if !matched {
                let w = words[i]
                let complete = i < words.count - 1 || lastComplete
                switch w {
                case "i": out.append((1, "I"))
                case "i'm", "i'll", "i've", "i'd": out.append((1, "I" + w.dropFirst()))
                default:
                    if fix, complete, let better = fixWord(w) {
                        out.append((1, better))
                    } else {
                        out.append((1, w))
                    }
                }
                i += 1
            }
        }
        return out
    }

    public func join(_ a: String, _ b: String, options: EngineOptions) -> String {
        guard let la = a.last else { return b }
        guard let fb = b.first else { return a }
        let aCJK = ScriptConverter.isCJK(la) || MixEngine.isCJKPunct(la)
        let bCJK = ScriptConverter.isCJK(fb) || MixEngine.isCJKPunct(fb)
        if aCJK && bCJK { return a + b }
        if la == " " || fb == " " { return a + b }
        if MixEngine.isCJKPunct(la) || MixEngine.isCJKPunct(fb) { return a + b }
        if aCJK != bCJK { return a + (options.spaceBetweenScripts ? " " : "") + b }
        return a + " " + b
    }

    static func isCJKPunct(_ c: Character) -> Bool { "，。？！；：、（）《》「」『』…—“”‘’".contains(c) }

    // MARK: - Analysis

    public func analyze(_ raw: String, options: EngineOptions = EngineOptions()) -> Analysis {
        var tokens = tokenize(raw)
        guard !tokens.isEmpty else {
            return Analysis(raw: raw, tokens: [], preview: "", previewReading: nil, candidates: [])
        }
        let endsWithSpace = raw.last == " "
        classify(&tokens, rawEndsWithSpace: endsWithSpace)
        let rs = runs(tokens)

        var converted: [String] = []
        var results: [PinyinConverter.Result?] = []
        for (idx, run) in rs.enumerated() {
            if run.kind == .chinese {
                let text = String(Array(raw)[run.start..<run.end])
                let isLastRun = idx == rs.count - 1 && !endsWithSpace
                if let r = pinyin.convert(text, allowPartialEnd: isLastRun) {
                    converted.append(r.sentence)
                    results.append(r)
                    continue
                }
            }
            converted.append(caseEnglish(run.tokens.map(\.text), lastComplete: endsWithSpace || idx < rs.count - 1).joined(separator: " "))
            results.append(nil)
        }

        // Segments: Chinese run = 1 segment; English = 1 per word / name.
        var segments: [Segment] = []
        for (idx, run) in rs.enumerated() {
            if run.kind == .chinese, results[idx] != nil {
                segments.append(Segment(kind: .chinese, start: run.start, end: run.end, output: converted[idx],
                                        reading: results[idx]?.reading))
            } else {
                var t = 0
                for g in caseEnglishGroups(run.tokens.map(\.text), lastComplete: endsWithSpace || idx < rs.count - 1) {
                    let first = run.tokens[t], last = run.tokens[t + g.count - 1]
                    segments.append(Segment(kind: .english, start: first.start, end: last.end, output: g.text))
                    t += g.count
                }
            }
        }

        func assemble(_ parts: [String]) -> String {
            var s = ""
            for p in parts { s = join(s, p, options: options) }
            if options.capitalizeFirst, let f = s.first, f.isLowercase, f.isASCII {
                s = f.uppercased() + s.dropFirst()
            }
            return s
        }

        let preview = assemble(converted)
        let reading = results.compactMap { $0?.reading }.joined(separator: " ")
        var cands: [Candidate] = [Candidate(display: preview, output: preview, consumes: raw.count, kind: .smart,
                                            reading: reading.isEmpty ? nil : reading)]
        let ambiguous = tokens.contains { $0.ambiguous }

        // Alternative readings of the whole buffer
        let allEnglish = assemble([caseEnglish(tokens.map(\.text), fix: false).joined(separator: " ")])
        var flipped: String?
        if ambiguous {
            // flip every ambiguous token to the other script
            var alt = tokens
            for i in alt.indices where alt[i].ambiguous { alt[i].kind = alt[i].kind == .chinese ? .english : .chinese }
            var parts: [String] = []
            for (idx, run) in runs(alt).enumerated() {
                if run.kind == .chinese, let r = pinyin.convert(String(Array(raw)[run.start..<run.end]),
                                                                  allowPartialEnd: idx == runs(alt).count - 1 && !endsWithSpace) {
                    parts.append(r.sentence)
                } else {
                    parts.append(caseEnglish(run.tokens.map(\.text)).joined(separator: " "))
                }
            }
            flipped = assemble(parts)
        }
        var alternatives: [Candidate] = []
        if let f = flipped { alternatives.append(Candidate(display: f, output: f, consumes: raw.count, kind: .alternative)) }
        let englishCand = Candidate(display: allEnglish, output: allEnglish, consumes: raw.count, kind: .english)

        // Word choices for the first Chinese run
        var words: [Candidate] = []
        if let focus = rs.firstIndex(where: { $0.kind == .chinese }), let r = results[focus] {
            let before = assemble(Array(converted[..<focus]))
            let runStart = rs[focus].start
            for w in r.words {
                let consumes = min(raw.count, runStart + w.rawLength)
                let out = before.isEmpty ? w.text : join(before, w.text, options: options)
                words.append(Candidate(display: w.text, output: out, consumes: consumes, kind: .word, reading: w.reading))
            }
        }

        if ambiguous {
            cands.append(contentsOf: alternatives)
            cands.append(englishCand)
            cands.append(contentsOf: words)
        } else {
            cands.append(contentsOf: words.prefix(5))
            cands.append(englishCand)
            cands.append(contentsOf: words.dropFirst(5))
        }

        // de-duplicate (same text that uses up the same input)
        var seen = Set<String>()
        cands = cands.filter { c in
            let key = "\(c.consumes)|\(c.output)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return !c.display.isEmpty
        }
        return Analysis(raw: raw, segments: segments, tokens: tokens, preview: preview,
                        previewReading: reading.isEmpty ? nil : reading, candidates: cands)
    }
}
