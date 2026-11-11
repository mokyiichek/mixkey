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
}
