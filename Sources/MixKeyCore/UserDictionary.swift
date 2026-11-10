import Foundation

/// What MixKey learns from you, saved on this Mac only.
///  - Words you pick from the choice bar move to the top for that pinyin next time.
///  - Chinese phrases you send often get a gentle boost, so your usual combinations come first.
public final class UserDictionary {
    public struct Stat: Codable {
        public var picks: Int = 0
        public var uses: Int = 0
    }

    /// pinyin key ("ming tian") -> word -> stats
    private(set) var entries: [String: [String: Stat]] = [:]
    /// every proper prefix of every key ("ming" for "ming tian"), so the lattice can reach user phrases
    private(set) var prefixes: Set<String> = []
    private let url: URL?
    private var saveWork: DispatchWorkItem?

    public init(url: URL?) {
        self.url = url
        if let url = url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [String: Stat]].self, from: data) {
            entries = decoded
        }
        rebuildPrefixes()
    }

    public var isEmpty: Bool { entries.isEmpty }

    public func stats(for key: String) -> [String: Stat]? { entries[key] }

    public func hasLongerKey(_ key: String) -> Bool { prefixes.contains(key) }

    /// `picked`: the user chose it from the list (strong). Otherwise: it was sent as typed (gentle).
    public func learn(key: String, word: String, picked: Bool) {
        guard !key.isEmpty, !word.isEmpty else { return }
        var s = entries[key]?[word] ?? Stat()
        if picked { s.picks += 1 } else { s.uses += 1 }
        entries[key, default: [:]][word] = s
        let parts = key.split(separator: " ")
        if parts.count > 1 {
            for n in 1..<parts.count { prefixes.insert(parts.prefix(n).joined(separator: " ")) }
        }
        scheduleSave()
    }

    public func forget(key: String, word: String) {
        entries[key]?[word] = nil
        if entries[key]?.isEmpty == true { entries[key] = nil }
        rebuildPrefixes()
        scheduleSave()
    }

    public func clear() {
        entries = [:]
        prefixes = []
        scheduleSave()
    }

    private func rebuildPrefixes() {
        prefixes = []
        for key in entries.keys {
            let parts = key.split(separator: " ")
            if parts.count > 1 {
                for n in 1..<parts.count { prefixes.insert(parts.prefix(n).joined(separator: " ")) }
            }
        }
    }

    private func scheduleSave() {
        guard let url = url else { return }
        saveWork?.cancel()
        let snapshot = entries
        let work = DispatchWorkItem {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }
}
