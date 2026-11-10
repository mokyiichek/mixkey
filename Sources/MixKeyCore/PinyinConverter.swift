import Foundation

/// Converts a run of pinyin (e.g. "wo ming tian" or "womingtian") into Chinese
/// using a word lattice + best-path search over the lexicon.
public final class PinyinConverter {
    public struct Word: Equatable {
        public let text: String
        /// Number of raw characters (of the run string) this word covers, from the start.
        public let rawLength: Int
        /// Pinyin key, e.g. "ming tian".
        public let reading: String
        public let weight: Int
    }

    public struct Result {
        public let sentence: String
        public let reading: String
        /// Word choices for the start of the run, longest/most likely first.
        public let words: [Word]
    }

    let lex: Lexicon
    private static let maxSyllableLen = 6
    private static let maxWordSyllables = 8

    public init(lexicon: Lexicon) { lex = lexicon }

    // MARK: - Preparation

    struct Prepared {
        var letters: [Character] = []
        /// Positions (letter indices) where a syllable boundary is forced by a space or apostrophe.
        var forced: Set<Int> = []
        /// rawIndex[k] = offset in the raw string of letter k; rawIndex[n] = raw length.
        var rawIndex: [Int] = []
    }

    struct SylEdge {
        let to: Int
        /// One spelling for a full syllable; several for a trailing partial syllable.
        let spellings: [String]
        let partial: Bool
    }

    func prepare(_ raw: String) -> Prepared {
        var p = Prepared()
        for (offset, ch) in raw.enumerated() {
            if ch == " " || ch == "'" {
                p.forced.insert(p.letters.count)
            } else {
                p.rawIndex.append(offset)
                p.letters.append(Character(ch.lowercased()))
            }
        }
        p.rawIndex.append(raw.count)
        return p
    }

    func syllableEdges(_ p: Prepared, allowPartialEnd: Bool) -> [[SylEdge]] {
        let n = p.letters.count
        var edges = Array(repeating: [SylEdge](), count: n + 1)
        guard n > 0 else { return edges }
        for i in 0..<n {
            var len = 1
            while len <= PinyinConverter.maxSyllableLen && i + len <= n {
                // can't cross a forced boundary
                if len > 1 && p.forced.contains(i + len - 1) { break }
                let s = String(p.letters[i..<(i + len)])
                if lex.syllables.contains(s) {
                    edges[i].append(SylEdge(to: i + len, spellings: [s], partial: false))
                } else if let a = lex.syllableAlias[s] {
                    edges[i].append(SylEdge(to: i + len, spellings: [a], partial: false))
                } else if allowPartialEnd, i + len == n, let full = lex.syllablesByPrefix[s] {
                    edges[i].append(SylEdge(to: n, spellings: full, partial: true))
                }
                len += 1
            }
        }
        return edges
    }

    /// True when the whole string can be split into pinyin syllables.
    public func isPinyin(_ raw: String, allowPartialEnd: Bool) -> Bool {
        let p = prepare(raw)
        let n = p.letters.count
        guard n > 0, p.letters.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        let edges = syllableEdges(p, allowPartialEnd: allowPartialEnd)
        var reach = Array(repeating: false, count: n + 1)
        reach[0] = true
        for i in 0..<n where reach[i] {
            for e in edges[i] where e.to <= n {
                // a forced boundary must coincide with a syllable end
                reach[e.to] = true
            }
        }
        // make sure forced boundaries are respected: a path can't end mid-way through a forced gap,
        // which syllableEdges already guarantees.
        return reach[n]
    }

    // MARK: - Conversion

    struct WordEdge {
        let from: Int
        let to: Int
        let word: String
        let weight: Int
        let reading: String
    }

    public func convert(_ raw: String, allowPartialEnd: Bool) -> Result? {
        let p = prepare(raw)
        let n = p.letters.count
        guard n > 0 else { return nil }
        let syl = syllableEdges(p, allowPartialEnd: allowPartialEnd)

        // which positions are reachable from the start by whole syllables
        var reach = Array(repeating: false, count: n + 1)
        reach[0] = true
        for i in 0..<n where reach[i] { for e in syl[i] { reach[e.to] = true } }
        guard reach[n] else { return nil }

        // Build word edges by walking syllable paths and looking each key up.
        var wordEdges = Array(repeating: [WordEdge](), count: n + 1)
        for start in 0..<n where reach[start] {
            var stack: [(pos: Int, key: String, depth: Int)] = [(start, "", 0)]
            while let (pos, key, depth) = stack.popLast() {
                for e in syl[pos] {
                    for spelling in e.spellings {
                        let k = key.isEmpty ? spelling : key + " " + spelling
                        let entries = lex.lookup(k)
                        // keep a handful per key; partial expansions only the best few
                        for entry in entries.prefix(e.partial ? 3 : 12) {
                            wordEdges[start].append(WordEdge(from: start, to: e.to, word: entry.word, weight: entry.weight, reading: k))
                        }
                        if !e.partial, depth + 1 < PinyinConverter.maxWordSyllables, e.to < n, lex.hasLongerKey(k) {
                            stack.append((e.to, k, depth + 1))
                        }
                    }
                }
            }
        }

        // Best path (maximise sum of log-probabilities).
        let logT = log(lex.totalWeight)
        var best = Array(repeating: -Double.infinity, count: n + 1)
        var back: [WordEdge?] = Array(repeating: nil, count: n + 1)
        best[0] = 0
        for i in 0..<n where best[i] > -Double.infinity {
            for e in wordEdges[i] {
                let s = best[i] + log(Double(e.weight) + 1) - logT
                if s > best[e.to] {
                    best[e.to] = s
                    back[e.to] = e
                }
            }
        }
        guard best[n] > -Double.infinity else { return nil }
        var parts: [WordEdge] = []
        var cur = n
        while cur > 0, let e = back[cur] {
            parts.append(e)
            cur = e.from
        }
        parts.reverse()
        let sentence = parts.map(\.word).joined()
        let reading = parts.map(\.reading).joined(separator: " ")

        // Word candidates starting at 0
        var seen = Set<String>()
        var words: [Word] = []
        let starts = wordEdges[0].sorted {
            if $0.to != $1.to { return $0.to > $1.to }
            return $0.weight > $1.weight
        }
        for e in starts where !seen.contains(e.word) {
            seen.insert(e.word)
            words.append(Word(text: e.word, rawLength: rawLength(p, letters: e.to, total: n), reading: e.reading, weight: e.weight))
            if words.count >= 60 { break }
        }
        return Result(sentence: sentence, reading: reading, words: words)
    }

    /// Converts a letter count into a raw character count (including the separators that follow).
    private func rawLength(_ p: Prepared, letters: Int, total: Int) -> Int {
        letters >= total ? p.rawIndex[total] : p.rawIndex[letters]
    }
}
