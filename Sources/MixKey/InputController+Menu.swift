import AppKit
import InputMethodKit
import MixKeyCore

/// The MixKey menu under the input menu in the menu bar.
extension MixKeyInputController {
    // MARK: - Menu (shown under the input menu in the menu bar)

    override func menu() -> NSMenu! {
        let m = NSMenu(title: "MixKey")
        func item(_ title: String, _ action: Selector, on: Bool = false, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.state = on ? .on : .off
            i.tag = tag
            return i
        }
        let mode = Settings.shared.scriptMode
        m.addItem(item("Chinese: Auto-detect (简/繁)", #selector(menuScript(_:)), on: mode == .auto, tag: 0))
        m.addItem(item("Chinese: Always Simplified 简体", #selector(menuScript(_:)), on: mode == .simplified, tag: 1))
        m.addItem(item("Chinese: Always Traditional 繁體", #selector(menuScript(_:)), on: mode == .traditional, tag: 2))
        m.addItem(.separator())
        m.addItem(item("Space between Chinese and English", #selector(menuToggleSpace(_:)), on: Settings.shared.spaceBetweenScripts))
        m.addItem(item("Capitalise start of sentences", #selector(menuToggleCaps(_:)), on: Settings.shared.capitalizeSentences))
        m.addItem(item("Fix English spelling", #selector(menuToggleSpell(_:)), on: Settings.shared.autoFixSpelling))
        m.addItem(item("Show pinyin under words", #selector(menuTogglePinyin(_:)), on: Settings.shared.showPinyin))
        let themes = NSMenu(title: "Colour theme")
        for (i, t) in Theme.all.enumerated() {
            themes.addItem(item(t.name, #selector(menuTheme(_:)), on: t.id == Theme.current.id, tag: i))
        }
        let themeItem = NSMenuItem(title: "Colour theme 🎨", action: nil, keyEquivalent: "")
        themeItem.submenu = themes
        m.addItem(themeItem)
        m.addItem(item("Bigger text", #selector(menuBigger(_:))))
        m.addItem(item("Smaller text", #selector(menuSmaller(_:))))
        m.addItem(.separator())
        let hasKey = Settings.shared.apiKey != nil
        m.addItem(item(hasKey ? "✨ AI fixes (Claude)" : "✨ AI fixes (add API key first)", #selector(menuToggleAI(_:)),
                       on: hasKey && Settings.shared.aiEnabled))
        m.addItem(item(hasKey ? "Change Claude API key…" : "Add Claude API key…", #selector(menuAPIKey(_:))))
        m.addItem(.separator())
        m.addItem(item(ScriptDetector.hasAccessibility ? "Website detection: allowed ✓" : "Allow website detection (Accessibility)…",
                       #selector(menuAccessibility(_:))))
        m.addItem(item("Forget words MixKey learned", #selector(menuForget(_:))))
        m.addItem(item("About MixKey…", #selector(menuAbout(_:))))
        return m
    }

    /// IMK passes either the NSMenuItem or a dictionary containing it.
    private func menuItem(_ sender: Any?) -> NSMenuItem? {
        if let i = sender as? NSMenuItem { return i }
        if let d = sender as? [String: Any] { return d[kIMKCommandMenuItemName] as? NSMenuItem }
        return nil
    }

    @objc func menuScript(_ sender: Any?) {
        let tag = menuItem(sender)?.tag ?? 0
        Settings.shared.scriptMode = [.auto, .simplified, .traditional][tag]
        detectScript()
    }
    @objc func menuToggleSpace(_ sender: Any?) { Settings.shared.spaceBetweenScripts.toggle() }
    @objc func menuToggleCaps(_ sender: Any?) { Settings.shared.capitalizeSentences.toggle() }
    @objc func menuToggleSpell(_ sender: Any?) { Settings.shared.autoFixSpelling.toggle() }
    @objc func menuTogglePinyin(_ sender: Any?) { Settings.shared.showPinyin.toggle() }
    @objc func menuBigger(_ sender: Any?) { Settings.shared.fontSize = min(36, Settings.shared.fontSize + 2) }
    @objc func menuSmaller(_ sender: Any?) { Settings.shared.fontSize = max(12, Settings.shared.fontSize - 2) }
    @objc func menuToggleAI(_ sender: Any?) {
        if Settings.shared.apiKey == nil { menuAPIKey(sender); return }
        Settings.shared.aiEnabled.toggle()
    }
    @objc func menuTheme(_ sender: Any?) {
        let tag = menuItem(sender)?.tag ?? 0
        if Theme.all.indices.contains(tag) { Settings.shared.themeID = Theme.all[tag].id }
    }
    @objc func menuForget(_ sender: Any?) {
        Shared.shared.engine?.lexicon.user?.clear()
        Shared.shared.engine?.lexicon.userChanged()
        Shared.shared.engine?.keepWords = []
        UserDefaults.standard.removeObject(forKey: "keepWords")
    }
    @objc func menuAccessibility(_ sender: Any?) { ScriptDetector.requestAccessibility() }

    @objc func menuAPIKey(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Claude API key"
        alert.informativeText = """
        MixKey can use Claude to fix whole sentences (homophones, spelling, place names). \
        Only the letters you are typing are sent — never the rest of your document. \
        Password fields never reach input methods.

        The key is saved only on this Mac (~/Library/Application Support/MixKey, readable only by you). \
        Get a key at console.anthropic.com.
        """
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if Settings.shared.apiKey != nil { alert.addButton(withTitle: "Remove key") }
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if !field.stringValue.isEmpty {
                Settings.shared.apiKey = field.stringValue
                Settings.shared.aiEnabled = true
                AIAssist.shared.warmUp()
            }
        case .alertThirdButtonReturn:
            Settings.shared.apiKey = nil
        default:
            break
        }
    }

    @objc func menuAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        alert.messageText = "MixKey 混打 \(v)"
        alert.informativeText = """
        Type pinyin and English together — no switching.

        • ni hao → 你好      • port dickson → Port Dickson
        • Enter or Space twice: send    • 1–9: choose    • Esc: cancel
        • Shift+Enter: send letters exactly as typed
        • Tap Shift: English-only mode on/off
        • , . ? ! after Chinese become ，。？！
        """
        alert.runModal()
    }
}

/// Debug logging: `defaults write com.mixkey.inputmethod.MixKey debug -bool YES`, read with
/// `/usr/bin/log show --last 5m --predicate 'process == "MixKey"' | grep MixKey:`.
import os
let debugLogger = Logger(subsystem: "com.mixkey.inputmethod.MixKey", category: "debug")

func dlog(_ msg: @autoclosure () -> String) {
    guard UserDefaults.standard.bool(forKey: "debug") else { return }
    let text = msg()
    debugLogger.notice("MixKey: \(text, privacy: .public)")
}
