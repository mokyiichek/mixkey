import Foundation
import SQLite3

/// Read-only access to the MixKey SQLite lexicon (build/mixkey.db).
public final class Lexicon {
    public struct Entry: Equatable {
        public let word: String
        public let weight: Int
    }

    private var db: OpaquePointer?
    private var stmtLookup: OpaquePointer?
    private var stmtKeyPrefix: OpaquePointer?
    private var stmtEnglish: OpaquePointer?
    private var stmtProper: OpaquePointer?
    private var stmtPhrase: OpaquePointer?

    public let syllables: Set<String>
    /// Typed spelling -> dictionary spelling, e.g. "lue" -> "lve".
    public let syllableAlias: [String: String]
    /// Syllable prefixes (e.g. "zh", "xia") -> full syllables that start with it.
    public let syllablesByPrefix: [String: [String]]
    public let totalWeight: Double
    public let stPhraseMaxLen: Int
    /// Simplified char -> traditional char.
    public let stChars: [Character: Character]
    public let maxProperWords: Int

    private var lookupCache: [String: [Entry]] = [:]
    /// What the user taught MixKey; merged into every lookup.
    public var user: UserDictionary? { didSet { lookupCache.removeAll(); prefixCache.removeAll() } }
    public func userChanged() { lookupCache.removeAll(); prefixCache.removeAll() }
    private var prefixCache: [String: Bool] = [:]

    public init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            throw NSError(domain: "MixKey", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot open lexicon at \(path)"])
        }
        func meta(_ db: OpaquePointer?, _ k: String) -> String? {
            Lexicon.queryStrings(db, "SELECT v FROM meta WHERE k='\(k)'").first
        }
        let syl = Set(Lexicon.queryStrings(db, "SELECT s FROM syllables"))
        var alias: [String: String] = [:]
        for pair in (meta(db, "syllable_alias") ?? "").split(separator: ",") {
            let p = pair.split(separator: "=")
            if p.count == 2 { alias[String(p[0])] = String(p[1]) }
        }
        var byPrefix: [String: [String]] = [:]
        for s in syl {
            for n in 1..<s.count { byPrefix[String(s.prefix(n)), default: []].append(s) }
        }
        var st: [Character: Character] = [:]
        for row in Lexicon.queryPairs(db, "SELECT s, t FROM st_char") {
            if row.0.count == 1, row.1.count == 1 { st[row.0.first!] = row.1.first! }
        }
        syllables = syl
        syllableAlias = alias
        syllablesByPrefix = byPrefix
        totalWeight = Double(meta(db, "total_weight") ?? "1") ?? 1
        stPhraseMaxLen = Int(meta(db, "st_phrase_maxlen") ?? "8") ?? 8
        stChars = st
        maxProperWords = Int(Lexicon.queryStrings(db, "SELECT max(words) FROM proper").first ?? "3") ?? 3

        sqlite3_prepare_v2(db, "SELECT word, weight FROM words WHERE key=?1 ORDER BY weight DESC LIMIT 40", -1, &stmtLookup, nil)
        sqlite3_prepare_v2(db, "SELECT 1 FROM words WHERE key >= ?1 AND key < ?2 LIMIT 1", -1, &stmtKeyPrefix, nil)
        sqlite3_prepare_v2(db, "SELECT rank FROM english WHERE word=?1", -1, &stmtEnglish, nil)
        sqlite3_prepare_v2(db, "SELECT proper FROM proper WHERE lower=?1", -1, &stmtProper, nil)
        sqlite3_prepare_v2(db, "SELECT t FROM st_phrase WHERE s=?1", -1, &stmtPhrase, nil)
    }

    deinit {
        for s in [stmtLookup, stmtKeyPrefix, stmtEnglish, stmtProper, stmtPhrase] { sqlite3_finalize(s) }
        sqlite3_close(db)
    }

    // MARK: - Pinyin

    /// Words for an exact syllable key such as "ni hao", best first.
    public func lookup(_ key: String) -> [Entry] {
        if let hit = lookupCache[key] { return hit }
        var out: [Entry] = []
        guard let st = stmtLookup else { return out }
        sqlite3_reset(st)
        bind(st, 1, key)
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(Entry(word: String(cString: sqlite3_column_text(st, 0)), weight: Int(sqlite3_column_int64(st, 1))))
        }
        if let learned = user?.stats(for: key) {
            // Picked words go above the current best; often-used phrases get a gentle lift.
            let top = out.first?.weight ?? 1000
            var merged: [String: Int] = [:]
            for e in out { merged[e.word] = e.weight }
            for (word, st) in learned {
                var w = merged[word] ?? 0
                if st.picks > 0 { w = max(w, top + 1) + st.picks * 1000 + st.uses * 100 }
                else if st.uses > 0 { w += Int(Double(max(top, w)) * min(0.6, 0.15 * Double(st.uses))) }
                merged[word] = w
            }
            out = merged.map { Entry(word: $0.key, weight: $0.value) }.sorted { $0.weight > $1.weight }
        }
        if lookupCache.count > 20000 { lookupCache.removeAll(keepingCapacity: true) }
        lookupCache[key] = out
        return out
    }

    /// True if some dictionary key is longer than and starts with `key + " "`.
    public func hasLongerKey(_ key: String) -> Bool {
        if let hit = prefixCache[key] { return hit }
        if user?.hasLongerKey(key) == true { return true }
        guard let st = stmtKeyPrefix else { return false }
        sqlite3_reset(st)
        bind(st, 1, key + " ")
        bind(st, 2, key + "!")
        let found = sqlite3_step(st) == SQLITE_ROW
        if prefixCache.count > 20000 { prefixCache.removeAll(keepingCapacity: true) }
        prefixCache[key] = found
        return found
    }

    // MARK: - English & proper nouns

    /// Frequency rank (1 = most common) of an English word, or nil.
    public func englishRank(_ word: String) -> Int? {
        guard let st = stmtEnglish else { return nil }
        sqlite3_reset(st)
        bind(st, 1, word.lowercased())
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : nil
    }

    /// All English words up to a frequency rank (for the spelling fixer).
    public func allEnglish(maxRank: Int) -> [(String, Int)] {
        var st: OpaquePointer?
        var out: [(String, Int)] = []
        if sqlite3_prepare_v2(db, "SELECT word, rank FROM english WHERE rank <= \(maxRank)", -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                out.append((String(cString: sqlite3_column_text(st, 0)), Int(sqlite3_column_int64(st, 1))))
            }
        }
        sqlite3_finalize(st)
        return out
    }

    /// Correctly capitalised form of a (possibly multi-word) proper noun, given lowercase text.
    public func properNoun(_ lower: String) -> String? {
        guard let st = stmtProper else { return nil }
        sqlite3_reset(st)
        bind(st, 1, lower)
        return sqlite3_step(st) == SQLITE_ROW ? String(cString: sqlite3_column_text(st, 0)) : nil
    }

    /// True if some multi-word proper noun starts with these words ("port" -> Port Dickson / Port Klang).
    public func startsProperNoun(_ lower: String) -> Bool {
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM proper WHERE lower >= ?1 AND lower < ?2 LIMIT 1", -1, &st, nil) == SQLITE_OK else { return false }
        bind(st!, 1, lower + " ")
        bind(st!, 2, lower + "!")
        return sqlite3_step(st) == SQLITE_ROW
    }

    public func stPhrase(_ s: String) -> String? {
        guard let st = stmtPhrase else { return nil }
        sqlite3_reset(st)
        bind(st, 1, s)
        return sqlite3_step(st) == SQLITE_ROW ? String(cString: sqlite3_column_text(st, 0)) : nil
    }

    // MARK: - helpers

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ st: OpaquePointer, _ idx: Int32, _ s: String) {
        sqlite3_bind_text(st, idx, s, -1, Lexicon.SQLITE_TRANSIENT)
    }

    private static func queryStrings(_ db: OpaquePointer?, _ sql: String) -> [String] {
        var st: OpaquePointer?
        var out: [String] = []
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                if let c = sqlite3_column_text(st, 0) { out.append(String(cString: c)) }
            }
        }
        sqlite3_finalize(st)
        return out
    }

    private static func queryPairs(_ db: OpaquePointer?, _ sql: String) -> [(String, String)] {
        var st: OpaquePointer?
        var out: [(String, String)] = []
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                out.append((String(cString: sqlite3_column_text(st, 0)), String(cString: sqlite3_column_text(st, 1))))
            }
        }
        sqlite3_finalize(st)
        return out
    }
}
