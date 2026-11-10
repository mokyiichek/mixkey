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
if let i = args.firstIndex(of: "--spell") {
    args.remove(at: i)
    for w in args {
        let t0 = Date()
        let f = engine.fixWord(w)
        print("\(w) -> \(f ?? "(keep)")   [\(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000)) ms]")
    }
    exit(0)
}
// --type: simulate typing key by key with the input method's send-as-you-type rule
if let i = args.firstIndex(of: "--type") {
    args.remove(at: i)
    for sentence in args {
        var raw = "", sent = "", lead = ""
        var opts = EngineOptions(); opts.capitalizeFirst = true
        func send(_ t: String) {
            let x = lead.isEmpty ? t : String(engine.join(lead, t, options: opts).dropFirst(lead.count))
            sent += x; lead = String(x.suffix(1))
        }
        for ch in sentence + "\n" {
            if ch == "\n" { send(engine.analyze(raw, options: opts).preview); raw = ""; break }
            raw.append(ch)
            let a = engine.analyze(raw, options: opts)
            if a.segments.count > 2, let last = a.segments.dropLast(2).last, last.end < raw.count {
                var text = ""
                for seg in a.segments.dropLast(2) { text = engine.join(text, seg.output, options: opts) }
                if opts.capitalizeFirst, let f = text.first, f.isLowercase { text = f.uppercased() + text.dropFirst() }
                send(text)
                raw = String(raw.dropFirst(last.end)).trimmingCharacters(in: .whitespaces)
                opts.capitalizeFirst = false
            }
        }
        print("\(sentence)\n   => \(sent)")
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
