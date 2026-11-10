import Foundation

/// Offline typo fixer: finds the most likely intended English word using
///  - a keyboard-aware edit distance (neighbouring keys, swapped letters and doubled letters are cheap)
///  - word frequency (common words win: "neex" -> "need", not "nix")
public final class SpellFixer {
    public struct Fix: Equatable {
        public let word: String
        public let cost: Double
        public let rank: Int
    }

    private var byLength: [Int: [(word: [UInt8], text: String, rank: Int)]] = [:]
    private let rankOf: [String: Int]

    /// Words that must never be "corrected" (Malaysian English, chat words, particles).
    public static let protected: Set<String> = [
        "la", "lah", "lor", "leh", "meh", "mah", "ah", "wah", "aiyo", "aiyoh", "aiya", "alamak", "walao", "wei",
        "makan", "tapau", "boleh", "jom", "sudah", "lagi", "kan", "ya", "yah", "tak", "nak", "dah", "pun", "je",
        "ok", "okay", "okie", "lol", "omg", "btw", "idk", "pls", "plz", "thx", "tq", "ty", "ur", "u", "k", "hehe",
        "haha", "hahaha", "hmm", "hmmm", "eh", "oi", "bro", "sis", "kopi", "teh", "roti", "mamak", "kampung",
        "mok", "uni", "uniness",
    ]

    public init(lexicon: Lexicon, maxRank: Int = 40000) {
        var map: [String: Int] = [:]
        for (w, r) in lexicon.allEnglish(maxRank: maxRank) {
            map[w] = r
            let bytes = Array(w.utf8)
            byLength[bytes.count, default: []].append((bytes, w, r))
        }
        rankOf = map
    }

    /// Best fix for a lowercase word, or nil if nothing good enough. `extra` = guesses from another
    /// source (e.g. the macOS spell checker), which are scored the same way.
    public func best(for word: String, extra: [String] = [], preferred: String? = nil) -> Fix? {
        let w = Array(word.lowercased().utf8)
        guard w.count >= 2, w.count <= 24, w.allSatisfy({ $0 >= 97 && $0 <= 122 || $0 == 39 }) else { return nil }
        let maxCost: Double = w.count <= 3 ? 1.0 : (w.count <= 5 ? 1.6 : 2.6)

        var best: (score: Double, fix: Fix)?
        func consider(_ text: String, _ bytes: [UInt8], _ rank: Int, bonus: Double = 0) {
            guard text != word else { return }
            let c = SpellFixer.distance(w, bytes, limit: maxCost)
            guard c <= maxCost else { return }
            let score = c + 0.35 * log10(Double(max(rank, 1))) - bonus
            if best == nil || score < best!.score { best = (score, Fix(word: text, cost: c, rank: rank)) }
        }
        // Typos almost always keep the first letter (or hit a neighbouring key / swap the first two).
        let f0 = w[0], f1 = w[1]
        for len in max(1, w.count - 2)...(w.count + 2) {
            for e in byLength[len] ?? [] {
                let g0 = e.word[0]
                guard g0 == f0 || g0 == f1 || SpellFixer.adjacent(g0, f0) else { continue }
                consider(e.text, e.word, e.rank)
            }
        }
        for g in extra + (preferred.map { [$0] } ?? []) {
            let lower = g.lowercased()
            guard !lower.contains(" "), !lower.contains("-") else { continue }
            // the system's own autocorrection is usually right when it has one
            consider(g, Array(lower.utf8), rankOf[lower] ?? 45000, bonus: g == preferred ? 0.8 : 0)
        }
        return best?.fix
    }

    public func rank(_ word: String) -> Int? { rankOf[word.lowercased()] }

    // MARK: - Keyboard-aware edit distance (optimal string alignment)

    private static let rows: [String] = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private static let keyPos: [UInt8: (Double, Double)] = {
        var m: [UInt8: (Double, Double)] = [:]
        for (r, row) in rows.enumerated() {
            for (c, ch) in row.utf8.enumerated() { m[ch] = (Double(r), Double(c) + Double(r) * 0.5) }
        }
        return m
    }()

    static func adjacent(_ a: UInt8, _ b: UInt8) -> Bool {
        guard let p = keyPos[a], let q = keyPos[b] else { return false }
        return abs(p.0 - q.0) <= 1 && abs(p.1 - q.1) <= 1.0
    }

    static func distance(_ a: [UInt8], _ b: [UInt8], limit: Double) -> Double {
        let n = a.count, m = b.count
        if abs(n - m) > 3 { return .infinity }
        var d = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = Double(i) }
        for j in 0...m { d[0][j] = Double(j) }
        for i in 1...n {
            var rowMin = Double.infinity
            for j in 1...m {
                let ai = a[i - 1], bj = b[j - 1]
                var best: Double
                if ai == bj {
                    best = d[i - 1][j - 1]
                } else {
                    best = d[i - 1][j - 1] + (adjacent(ai, bj) ? 0.5 : 1.0)
                }
                // extra letter typed (deletion): cheap if it's a doubled or neighbouring key
                var del = 1.0
                if i >= 2 && (a[i - 2] == ai || adjacent(a[i - 2], ai)) { del = 0.6 }
                if i < n && adjacent(a[i], ai) { del = min(del, 0.6) }
                best = min(best, d[i - 1][j] + del)
                // letter missed (insertion)
                var ins = 1.0
                if j >= 2 && b[j - 2] == bj { ins = 0.6 } // missed a doubled letter
                best = min(best, d[i][j - 1] + ins)
                // swapped letters
                if i >= 2 && j >= 2 && ai == b[j - 2] && a[i - 2] == bj {
                    best = min(best, d[i - 2][j - 2] + 0.6)
                }
                d[i][j] = best
                rowMin = min(rowMin, best)
            }
            if rowMin > limit + 0.01 { return .infinity }
        }
        return d[n][m]
    }
}
