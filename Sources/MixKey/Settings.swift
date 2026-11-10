import Foundation
import MixKeyCore

/// User preferences (stored in UserDefaults for the input method's bundle id).
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    enum ScriptMode: String, CaseIterable {
        case auto, simplified, traditional
    }

    private init() {
        d.register(defaults: [
            "scriptMode": ScriptMode.auto.rawValue,
            "defaultScript": ChineseScript.simplified.rawValue,
            "spaceBetweenScripts": true,
            "capitalizeSentences": true,
            "autoFixSpelling": true,
            "aiEnabled": true,
            "aiModel": "claude-haiku-5-5",
            "fontSize": 15.0,
            "showPinyin": false,
            "theme": "ocean",
        ])
    }

    var scriptMode: ScriptMode {
        get { ScriptMode(rawValue: d.string(forKey: "scriptMode") ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "scriptMode") }
    }
    /// Script used in Auto mode when nothing on screen gives a hint.
    var defaultScript: ChineseScript {
        get { ChineseScript(rawValue: d.string(forKey: "defaultScript") ?? "") ?? .simplified }
        set { d.set(newValue.rawValue, forKey: "defaultScript") }
    }
    var spaceBetweenScripts: Bool {
        get { d.bool(forKey: "spaceBetweenScripts") }
        set { d.set(newValue, forKey: "spaceBetweenScripts") }
    }
    var capitalizeSentences: Bool {
        get { d.bool(forKey: "capitalizeSentences") }
        set { d.set(newValue, forKey: "capitalizeSentences") }
    }
    var autoFixSpelling: Bool {
        get { d.bool(forKey: "autoFixSpelling") }
        set { d.set(newValue, forKey: "autoFixSpelling") }
    }
    var aiEnabled: Bool {
        get { d.bool(forKey: "aiEnabled") }
        set { d.set(newValue, forKey: "aiEnabled") }
    }
    var aiModel: String { d.string(forKey: "aiModel") ?? "claude-haiku-5-5" }
    var fontSize: CGFloat {
        get { CGFloat(d.double(forKey: "fontSize")) }
        set { d.set(Double(newValue), forKey: "fontSize") }
    }
    var themeID: String {
        get { d.string(forKey: "theme") ?? "ocean" }
        set { d.set(newValue, forKey: "theme") }
    }
    var showPinyin: Bool {
        get { d.bool(forKey: "showPinyin") }
        set { d.set(newValue, forKey: "showPinyin") }
    }

    // MARK: - API key (stored in a private file readable only by this Mac user)

    private var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MixKey", isDirectory: true)
    }
    private var keyFile: URL { supportDir.appendingPathComponent("anthropic_api_key") }

    var apiKey: String? {
        get {
            guard let s = try? String(contentsOf: keyFile, encoding: .utf8) else { return nil }
            let k = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return k.isEmpty ? nil : k
        }
        set {
            let fm = FileManager.default
            if let k = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
                try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                fm.createFile(atPath: keyFile.path, contents: Data(k.utf8), attributes: [.posixPermissions: 0o600])
            } else {
                try? fm.removeItem(at: keyFile)
            }
        }
    }
}
