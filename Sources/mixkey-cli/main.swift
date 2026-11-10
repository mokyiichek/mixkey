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
let inputs = args.isEmpty ? (readLine().map { [$0] } ?? []) : args
for input in inputs {
    let t0 = Date()
    let a = engine.analyze(input)
    let ms = Date().timeIntervalSince(t0) * 1000
    func s(_ x: String) -> String { trad ? engine.script.toTraditional(x) : x }
    print("\(input)  =>  \(s(a.preview))   [\(String(format: "%.1f", ms)) ms]")
    print("   tokens: " + a.tokens.map { "\($0.text):\($0.kind == .chinese ? "zh" : "en")\($0.ambiguous ? "?" : "")" }.joined(separator: " "))
    for (i, c) in a.candidates.prefix(9).enumerated() {
        print("   \(i + 1). \(s(c.display))  (\(c.kind), uses \(c.consumes))\(c.reading.map { "  " + $0 } ?? "")")
    }
}
