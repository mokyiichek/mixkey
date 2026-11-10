import Foundation
import MixKeyCore

/// Optional sentence-level "smart fix" using the Claude API (Messages API over HTTPS).
/// Only runs when the user has added an API key and AI assist is switched on.
/// Sends only the letters currently being composed (never surrounding text).
final class AIAssist {
    static let shared = AIAssist()

    private let session: URLSession
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private var inFlight: URLSessionDataTask?
    private(set) var lastError: String?

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: cfg)
    }

    var isAvailable: Bool { Settings.shared.aiEnabled && Settings.shared.apiKey != nil }

    private static let system = """
    You are the conversion engine inside a keyboard input method used in Malaysia. \
    The user types fast, mixing Hanyu Pinyin without tones and English, often with spelling mistakes \
    (the user has reading difficulty). Turn the raw keystrokes into the text they meant.
    Rules:
    - Pinyin becomes Simplified Chinese characters that fit the context.
    - English stays English: fix spelling mistakes; capitalise proper nouns, place names, brands and "I".
    - Malay words stay Malay.
    - Never translate between languages. Keep the user's words and order. Do not add words, \
    explanations, quotes, or ending punctuation.
    - %SPACING%
    - A dictionary-based guess is given; keep it when it is already right.
    Reply with only the converted text.
    """

    func cached(_ raw: String) -> String? { cache[raw] }

    func warmUp() {
        // Opens the TLS connection early so the first real request is faster.
        guard isAvailable, let url = URL(string: "https://api.anthropic.com/") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        session.dataTask(with: req).resume()
    }

    func convert(raw: String, localGuess: String, completion: @escaping (String?) -> Void) {
        if let hit = cache[raw] { completion(hit); return }
        guard isAvailable, let key = Settings.shared.apiKey,
              let url = URL(string: "https://api.anthropic.com/v1/messages") else { completion(nil); return }
        inFlight?.cancel()

        let spacing = Settings.shared.spaceBetweenScripts
            ? "Put one space between a Chinese part and an English part."
            : "Do not put spaces between Chinese and English parts."
        let body: [String: Any] = [
            "model": Settings.shared.aiModel,
            "max_tokens": 300,
            "thinking": ["type": "disabled"],
            "output_config": ["effort": "low"],
            "system": AIAssist.system.replacingOccurrences(of: "%SPACING%", with: spacing),
            "messages": [[
                "role": "user",
                "content": "Raw keystrokes: \(raw)\nDictionary guess: \(localGuess)",
            ]],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = session.dataTask(with: req) { [weak self] data, response, error in
            var result: String?
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let stop = json["stop_reason"] as? String, stop == "refusal" {
                    result = nil
                } else if let content = json["content"] as? [[String: Any]] {
                    let text = content.filter { ($0["type"] as? String) == "text" }
                        .compactMap { $0["text"] as? String }.joined()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    result = AIAssist.sanitize(text, raw: raw)
                } else if let err = json["error"] as? [String: Any] {
                    self?.lastError = err["message"] as? String
                }
            } else if let error = error as NSError?, error.code != NSURLErrorCancelled {
                self?.lastError = error.localizedDescription
            }
            DispatchQueue.main.async {
                if let r = result { self?.store(raw, r) }
                completion(result)
            }
        }
        inFlight = task
        task.resume()
    }

    /// Rejects replies that don't look like a conversion (explanations, multiple lines, far too long).
    static func sanitize(_ text: String, raw: String) -> String? {
        var t = text
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count > 2 { t = String(t.dropFirst().dropLast()) }
        guard !t.isEmpty, !t.contains("\n"), t.count <= raw.count * 3 + 10 else { return nil }
        return t
    }

    private func store(_ raw: String, _ text: String) {
        cache[raw] = text
        cacheOrder.append(raw)
        if cacheOrder.count > 300 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }
}
