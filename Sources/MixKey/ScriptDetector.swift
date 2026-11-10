import AppKit
import ApplicationServices
import InputMethodKit
import MixKeyCore

/// Works out whether the place you're typing into uses Simplified or Traditional Chinese.
///
/// Signals, strongest first:
///  1. Chinese already in the text field around the cursor.
///  2. The web page address (e.g. *.tw, *.hk, zh-TW, zh-Hant) — needs Accessibility permission.
///  3. The window / page title.
///  4. What was detected last time in the same app or website.
final class ScriptDetector {
    private let converter: ScriptConverter
    private var memory: [String: ChineseScript] = [:]

    init(converter: ScriptConverter) { self.converter = converter }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    struct Result {
        let script: ChineseScript
        let reason: String
    }

    func detect(client: (IMKTextInput & NSObjectProtocol)?, fallback: ChineseScript) -> Result {
        let bundleID = client?.bundleIdentifier() ?? "?"

        // 1. Text around the cursor
        if let c = client {
            let sel = c.selectedRange()
            if sel.location != NSNotFound {
                let start = max(0, sel.location - 400)
                let range = NSRange(location: start, length: sel.location - start + 200)
                if let text = c.string(from: range, actualRange: nil), let s = converter.detect(text) {
                    memory[bundleID] = s
                    return Result(script: s, reason: "text in this field")
                }
            }
        }

        // 2 + 3. Accessibility: page URL and window title of the frontmost app
        var memoryKey = bundleID
        if ScriptDetector.hasAccessibility, let app = NSWorkspace.shared.frontmostApplication {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            if let url = webAreaURL(axApp) {
                if let host = url.host { memoryKey = host }
                if let s = scriptFromURL(url) {
                    memory[memoryKey] = s
                    return Result(script: s, reason: "website \(url.host ?? "")")
                }
            }
            if let title = focusedWindowTitle(axApp), let s = converter.detect(title) {
                memory[memoryKey] = s
                return Result(script: s, reason: "window title")
            }
        }

        // 4. Memory
        if let s = memory[memoryKey] { return Result(script: s, reason: "last time here") }
        return Result(script: fallback, reason: "default")
    }

    // MARK: - URL heuristics

    func scriptFromURL(_ url: URL) -> ChineseScript? {
        let s = url.absoluteString.lowercased()
        let host = url.host?.lowercased() ?? ""
        let tradHosts = [".tw", ".hk", ".mo"]
        let simpHosts = [".cn"]
        if tradHosts.contains(where: { host.hasSuffix($0) }) { return .traditional }
        if simpHosts.contains(where: { host.hasSuffix($0) }) { return .simplified }
        let tradMarks = ["zh-tw", "zh_tw", "zh-hk", "zh_hk", "zh-hant", "zh_hant", "hant", "lang=tw", "/tw/", "/hk/", "big5"]
        let simpMarks = ["zh-cn", "zh_cn", "zh-hans", "zh_hans", "hans", "zh-sg", "/cn/"]
        if tradMarks.contains(where: { s.contains($0) }) { return .traditional }
        if simpMarks.contains(where: { s.contains($0) }) { return .simplified }
        return nil
    }

    // MARK: - Accessibility helpers

    private func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private func focusedWindowTitle(_ app: AXUIElement) -> String? {
        guard let win = attr(app, kAXFocusedWindowAttribute) else { return nil }
        return attr(win as! AXUIElement, kAXTitleAttribute) as? String
    }

    /// Walks up from the focused element to the enclosing web area and reads its URL.
    private func webAreaURL(_ app: AXUIElement) -> URL? {
        guard let focused = attr(app, kAXFocusedUIElementAttribute) else { return nil }
        var el = focused as! AXUIElement
        for _ in 0..<40 {
            if (attr(el, kAXRoleAttribute) as? String) == "AXWebArea" {
                if let u = attr(el, "AXURL") as? URL { return u }
                if let s = attr(el, "AXURL") as? String { return URL(string: s) }
                return nil
            }
            guard let parent = attr(el, kAXParentAttribute) else { return nil }
            el = parent as! AXUIElement
        }
        return nil
    }
}
