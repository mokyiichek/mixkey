import Foundation

public enum ChineseScript: String, CaseIterable {
    case simplified
    case traditional
}

/// Simplified -> Traditional conversion (OpenCC tables) and script detection.
public final class ScriptConverter {
    let lex: Lexicon
    /// Characters that only appear in simplified text (e.g. 们 说 这).
    let simplifiedOnly: Set<Character>
    /// Characters that only appear in traditional text (e.g. 們 說 這).
    let traditionalOnly: Set<Character>

    public init(lexicon: Lexicon) {
        lex = lexicon
        var simp = Set<Character>()
        var trad = Set<Character>()
        for (s, t) in lexicon.stChars where s != t {
            simp.insert(s)
            trad.insert(t)
        }
        let both = simp.intersection(trad)
        simplifiedOnly = simp.subtracting(both)
        traditionalOnly = trad.subtracting(both).subtracting(Set(lexicon.stChars.keys))
    }

    /// Converts simplified Chinese to traditional; non-Chinese text is left untouched.
    public func toTraditional(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        let maxLen = max(2, min(lex.stPhraseMaxLen, 12))
        while i < chars.count {
            let c = chars[i]
            guard ScriptConverter.isCJK(c) else {
                out.append(c)
                i += 1
                continue
            }
            var matched = false
            var len = min(maxLen, chars.count - i)
            while len >= 2 {
                let piece = String(chars[i..<(i + len)])
                if let t = lex.stPhrase(piece) {
                    out += t
                    i += len
                    matched = true
                    break
                }
                len -= 1
            }
            if !matched {
                out.append(lex.stChars[c] ?? c)
                i += 1
            }
        }
        return out
    }

    /// Guesses which script some text is written in. Returns nil when there is no signal.
    public func detect(_ text: String) -> ChineseScript? {
        var s = 0
        var t = 0
        for c in text {
            if simplifiedOnly.contains(c) { s += 1 } else if traditionalOnly.contains(c) { t += 1 }
        }
        if s == 0 && t == 0 { return nil }
        if t > s { return .traditional }
        if s > t { return .simplified }
        return nil
    }

    public static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3400...0x9FFF).contains(v) || (0x20000...0x3134F).contains(v) || (0xF900...0xFAFF).contains(v)
    }
}
