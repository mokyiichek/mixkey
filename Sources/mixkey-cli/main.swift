import Foundation
import MixKeyCore

// Try the engine from the terminal:
//   swift run mixkey-cli "wo ming tian qu port dickson"
//   swift run mixkey-cli --trad "wo men qu kan dian ying"

var args = Array(CommandLine.arguments.dropFirst())
var trad = false
if let i = args.firstIndex(of: "--trad") { trad = true; args.remove(at: i) }
var dbPath = "build/mixkey.db"
if let i = args.firstIndex(of: "--db"), i + 1 < args.count { dbPath = args[i + 1]; args.removeSubrange(i...(i + 1)) }

let engine = try MixEngine(lexiconPath: dbPath)
// --learn "shi=时": pretend the user picked these (in-memory only)
engine.lexicon.user = UserDictionary(url: nil)
while let i = args.firstIndex(of: "--learn"), i + 1 < args.count {
    let p = args[i + 1].split(separator: "=").map(String.init)
    if p.count == 2 { engine.learn(reading: p[0], word: p[1], picked: true) }
    args.removeSubrange(i...(i + 1))
}
if let i = args.firstIndex(of: "--spell") {
    args.remove(at: i)
    for w in args {
        let t0 = Date()
        let f = engine.fixWord(w)
        print("\(w) -> \(f ?? "(keep)")   [\(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000)) ms]")
    }
    exit(0)
}
// --type: simulate typing key by key with the input method's send-as-you-type rule.
// Prints what is in the app after each space:  sent text | still open
if let i = args.firstIndex(of: "--type") {
    args.remove(at: i)
    for sentence in args {
        var raw = "", sent = "", lead = ""
        var opts = EngineOptions(); opts.capitalizeFirst = true
        var steps: [String] = []
        func send(_ t: String) {
            let x = lead.isEmpty ? t : String(engine.join(lead, t, options: opts).dropFirst(lead.count))
            sent += x; lead = String(x.suffix(1))
        }
        for ch in sentence {
            raw.append(ch)
            let a = engine.analyze(raw, options: opts)
            let n = engine.settledCount(a)
            if n > 0, a.segments[n - 1].end < raw.count || raw.hasSuffix(" ") {
                let done = a.segments.prefix(n)
                var text = ""
                for seg in done { text = engine.join(text, seg.output, options: opts) }
                if opts.capitalizeFirst, let f = text.first, f.isLowercase { text = f.uppercased() + text.dropFirst() }
                let rest = String(String(raw.dropFirst(done.last!.end)).drop(while: { $0 == " " }))
                if rest.isEmpty, raw.hasSuffix(" "), done.last!.kind == .english { text += " " }
                if ProcessInfo.processInfo.environment["MKDEBUG"] != nil { print("   send [\(text)] raw=[\(raw)] n=\(n) segs=\(a.segments.map(\.output))") }
                send(text)
                raw = rest
                opts.capitalizeFirst = false
            }
            if ch == " " { steps.append(sent + " | " + engine.analyze(raw, options: opts).preview) }
        }
        if !raw.isEmpty { send(engine.analyze(raw + " ", options: opts).preview) }
        print("\(sentence)\n   => \(sent)")
        for st in steps { print("      \(st)") }
    }
    exit(0)
}
let inputs = args.isEmpty ? (readLine().map { [$0] } ?? []) : args
for input in inputs {
    let t0 = Date()
    let a = engine.analyze(input)
    let ms = Date().timeIntervalSince(t0) * 1000
    func s(_ x: String) -> String { trad ? engine.script.toTraditional(x) : x }
    print("\(input)  =>  \(s(a.preview))   [\(String(format: "%.1f", ms)) ms]")
    print("   segments: " + a.segments.map { "[\($0.output)]" }.joined(separator: " "))
    print("   tokens: " + a.tokens.map { "\($0.text):\($0.kind == .chinese ? "zh" : "en")\($0.ambiguous ? "?" : "")" }.joined(separator: " "))
    for (i, c) in a.candidates.prefix(9).enumerated() {
        print("   \(i + 1). \(s(c.display))  (\(c.kind), uses \(c.consumes))\(c.reading.map { "  " + $0 } ?? "")")
    }
}
