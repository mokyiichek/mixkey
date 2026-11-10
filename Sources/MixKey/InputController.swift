import AppKit
import InputMethodKit
import MixKeyCore

/// One controller per text-input client. Handles keys, composition and the candidate window.
@objc(MixKeyInputController)
final class MixKeyInputController: IMKInputController {
    // Composition state
    private var raw = ""          // letters + spaces being typed
    private var fixed = ""        // words already chosen but not yet sent to the app
    private var candidates: [Candidate] = []
    private var highlighted = 0
    private let pageSize = 9

    private var script: ChineseScript = .simplified
    private var scriptReason = ""
    private var capitalizeFirst = false
    private var lastCommitEndedChinese = false
    private var aiWork: DispatchWorkItem?
    private var aiPendingFor: String?

    private var lastDetect = Date.distantPast
    private var shiftAlone = false
    private var shiftDownAt = Date.distantPast

    /// The text field we're typing into. IMK passes it with every call; `client()` can be nil in
    /// Chrome / Electron apps, so remember the one we were given.
    private weak var activeClient: (IMKTextInput & NSObjectProtocol)?
    private func cl() -> (IMKTextInput & NSObjectProtocol)? {
        activeClient ?? (super.client() as (IMKTextInput & NSObjectProtocol)?)
    }
    private func adopt(_ sender: Any?) {
        if let c = sender as? (IMKTextInput & NSObjectProtocol) { activeClient = c }
    }

    private var shared: Shared { .shared }
    private var engine: MixEngine? { shared.engine }
    private var isComposing: Bool { !raw.isEmpty || !fixed.isEmpty }

    private static let notFound = NSRange(location: NSNotFound, length: NSNotFound)
    private static let fullWidth: [Character: String] = [
        ",": "，", ".": "。", "?": "？", "!": "！", ";": "；", ":": "：", "\\": "、",
        "(": "（", ")": "）", "<": "《", ">": "》", "[": "「", "]": "」",
    ]
    /// Apps where automatic capitalisation would get in the way.
    private static let codeApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode", "com.apple.dt.Xcode",
        "dev.warp.Warp-Stable", "com.todesktop.230313mzl4w4u92", "com.sublimetext.4", "com.jetbrains.intellij",
    ]

    // MARK: - IMK lifecycle

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        adopt(sender)
        dlog("activate client=\(cl()?.bundleIdentifier() ?? "nil")")
        detectScript()
        AIAssist.shared.warmUp()
        shared.panel.onSelect = { [weak self] i in
            guard let self = self else { return }
            self.select(self.pageStart + i)
        }
    }

    override func deactivateServer(_ sender: Any!) {
        adopt(sender)
        if isComposing { commitTop() }
        shared.panel.hide()
        lastCommitEndedChinese = false
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        adopt(sender)
        if isComposing { commitTop() }
    }

    // MARK: - Keys

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        adopt(sender)
        guard let event = event else { return false }
        if event.type == .keyDown { dlog("key \(event.keyCode) '\(event.characters ?? "")' app=\(cl()?.bundleIdentifier() ?? "nil") client=\(cl() == nil ? "nil" : "ok") raw='\(raw)'") }

        if event.type == .flagsChanged {
            handleShift(event)
            return false
        }
        guard event.type == .keyDown else { return false }
        shiftAlone = false

        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if !mods.isEmpty {
            if isComposing { commitTop() }
            return false
        }
        guard engine != nil, cl() != nil else { return false }

        if shared.englishMode {
            lastCommitEndedChinese = false
            return false
        }

        let chars = event.characters ?? ""
        switch event.keyCode {
        case 36, 76: // Return / Enter
            guard isComposing else { lastCommitEndedChinese = false; return false }
            if event.modifierFlags.contains(.shift) { commitLiteral() } else { select(highlighted) }
            return true
        case 53: // Esc
            guard isComposing else { return false }
            reset()
            return true
        case 51: // Delete
            guard isComposing else { return false }
            if !raw.isEmpty { raw.removeLast() } else if !fixed.isEmpty { fixed.removeLast() }
            if !isComposing { reset() } else { refresh() }
            return true
        case 49: // Space
            guard isComposing else { lastCommitEndedChinese = false; return false }
            if raw.isEmpty || raw.hasSuffix(" ") {
                // double space = send what's shown
                raw = raw.trimmingCharacters(in: .whitespaces)
                let out = currentOutput()
                commit(out + (endsLatin(out) ? " " : ""))
            } else {
                raw += " "
                refresh()
            }
            return true
        case 125, 48: // Down, Tab
            guard isComposing else { return false }
            moveHighlight(event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case 126: // Up
            guard isComposing else { return false }
            moveHighlight(-1)
            return true
        case 121, 124: // Page Down, Right
            guard isComposing else { return false }
            moveHighlight(pageSize - highlighted % pageSize)
            return true
        case 116, 123: // Page Up, Left
            guard isComposing else { return false }
            moveHighlight(-(highlighted % pageSize) - (highlighted >= pageSize ? pageSize : 0))
            return true
        default:
            break
        }

        guard chars.count == 1, let c = chars.first else {
            if isComposing { commitTop() }
            return false
        }

        if c.isASCII && c.isLetter {
            if !isComposing { startComposition() }
            raw.append(c)
            refresh()
            return true
        }
        if c == "'" && !raw.isEmpty && !raw.hasSuffix(" ") {
            raw.append(c)
            refresh()
            return true
        }
        if let d = c.wholeNumberValue, c.isASCII, isComposing {
            if d >= 1 { select(pageStart + d - 1) }
            return true
        }
        if let full = MixKeyInputController.fullWidth[c] {
            if isComposing {
                let out = currentOutput()
                let chinese = out.last.map { ScriptConverter.isCJK($0) } ?? false
                commit(out + (chinese ? full : String(c)))
                return true
            }
            if lastCommitEndedChinese && ",.?!;:\\".contains(c) {
                cl()?.insertText(full, replacementRange: MixKeyInputController.notFound)
                return true
            }
            return false
        }
        // Any other key: send what we have, then let the app handle the key.
        if isComposing { commitTop() }
        lastCommitEndedChinese = false
        return false
    }

    private func handleShift(_ event: NSEvent) {
        guard event.keyCode == 56 || event.keyCode == 60 else { shiftAlone = false; return }
        if event.modifierFlags.contains(.shift) {
            shiftAlone = true
            shiftDownAt = Date()
        } else if shiftAlone, Date().timeIntervalSince(shiftDownAt) < 0.5 {
            shiftAlone = false
            toggleEnglishMode()
        }
    }

    private func toggleEnglishMode() {
        if isComposing { commitLiteral() }
        shared.englishMode.toggle()
        flashStatus(shared.englishMode ? "ABC  English only  (tap Shift to go back)" : "混  Pinyin + English")
    }

    // MARK: - Composition

    private func startComposition() {
        capitalizeFirst = false
        if Settings.shared.scriptMode == .auto, Date().timeIntervalSince(lastDetect) > 4 { detectScript() }
        guard Settings.shared.capitalizeSentences, let c = cl() else { return }
        if MixKeyInputController.codeApps.contains(c.bundleIdentifier() ?? "") { return }
        let sel = c.selectedRange()
        guard sel.location != NSNotFound else { return }
        if sel.location == 0 { capitalizeFirst = true; return }
        let start = max(0, sel.location - 40)
        var actual = NSRange(location: NSNotFound, length: 0)
        let before = c.string(from: NSRange(location: start, length: sel.location - start), actualRange: &actual) ?? ""
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            capitalizeFirst = before.isEmpty ? sel.location == 0 : start == 0
        } else if let last = trimmed.last {
            capitalizeFirst = ".!?。！？\n".contains(last)
        }
    }

    private var options: EngineOptions {
        var o = EngineOptions()
        o.spaceBetweenScripts = Settings.shared.spaceBetweenScripts
        o.capitalizeFirst = capitalizeFirst && fixed.isEmpty
        return o
    }

    private func s(_ text: String) -> String {
        script == .traditional ? (engine?.script.toTraditional(text) ?? text) : text
    }

    private func join(_ a: String, _ b: String) -> String {
        engine?.join(a, b, options: options) ?? a + b
    }

    private func refresh() {
        guard let engine = engine else { return }
        if raw.trimmingCharacters(in: .whitespaces).isEmpty {
            if fixed.isEmpty { reset() } else { candidates = []; render() }
            return
        }
        let a = engine.analyze(raw, options: options)
        var list = a.candidates
        let key = raw.trimmingCharacters(in: .whitespaces)
        if let ai = AIAssist.shared.cached(key), AIAssist.shared.isAvailable {
            list.removeAll { $0.consumes >= raw.count && $0.output == ai }
            list.insert(Candidate(display: ai, output: ai, consumes: raw.count, kind: .ai), at: 0)
        }
        candidates = list
        highlighted = 0
        render()
        scheduleAI(analysis: a)
    }

    private func scheduleAI(analysis a: Analysis) {
        aiWork?.cancel()
        let key = raw.trimmingCharacters(in: .whitespaces)
        guard AIAssist.shared.isAvailable, AIAssist.shared.cached(key) == nil else { return }
        // Worth asking when there's context to use: several words, a mix, or unknown English words.
        let worth = a.tokens.count >= 2 || a.tokens.contains { $0.ambiguous } || a.tokens.contains { $0.kind == .english && $0.text.count >= 4 }
        guard worth else { return }
        let guess = a.preview
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.raw.trimmingCharacters(in: .whitespaces) == key else { return }
            self.aiPendingFor = key
            self.render()
            AIAssist.shared.convert(raw: key, localGuess: guess) { [weak self] result in
                guard let self = self else { return }
                if self.aiPendingFor == key { self.aiPendingFor = nil }
                guard result != nil, self.raw.trimmingCharacters(in: .whitespaces) == key else {
                    if self.isComposing { self.render() }
                    return
                }
                self.refresh() // picks the cached AI result up as the first candidate
            }
        }
        aiWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    /// The text that would be sent right now (fixed part + highlighted/first full candidate).
    private func currentOutput() -> String {
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return fixed }
        let full = candidates.indices.contains(highlighted) && candidates[highlighted].consumes >= raw.count
            ? candidates[highlighted] : candidates.first
        return join(fixed, s(full?.output ?? raw))
    }

    private var pageStart: Int { (highlighted / pageSize) * pageSize }

    private func moveHighlight(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        highlighted = max(0, min(candidates.count - 1, highlighted + delta))
        render()
    }

    private func select(_ index: Int) {
        guard candidates.indices.contains(index) else {
            if candidates.isEmpty && isComposing { commit(fixed) }
            return
        }
        let c = candidates[index]
        if c.consumes >= raw.count {
            commit(join(fixed, s(c.output)))
        } else {
            fixed = join(fixed, s(c.output))
            raw = String(raw.dropFirst(c.consumes)).trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { commit(fixed) } else { refresh() }
        }
    }

    private func commitTop() {
        let out = currentOutput()
        commit(out)
    }

    /// Sends exactly what was typed (Shift+Enter).
    private func commitLiteral() {
        commit(join(fixed, raw.trimmingCharacters(in: .whitespaces)))
    }

    private func commit(_ text: String) {
        if !text.isEmpty {
            cl()?.insertText(text, replacementRange: MixKeyInputController.notFound)
            lastCommitEndedChinese = text.last.map { ScriptConverter.isCJK($0) } ?? false
        }
        reset(clearMarked: text.isEmpty)
    }

    private func reset(clearMarked: Bool = true) {
        raw = ""
        fixed = ""
        candidates = []
        highlighted = 0
        aiWork?.cancel()
        aiPendingFor = nil
        if clearMarked {
            cl()?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                    replacementRange: MixKeyInputController.notFound)
        }
        shared.panel.hide()
    }

    private func endsLatin(_ s: String) -> Bool {
        guard let l = s.last else { return false }
        return l.isASCII && (l.isLetter || l.isNumber)
    }

    // MARK: - Drawing

    private func render() {
        guard let client = cl() else { dlog("render: no client"); return }
        let composed = currentOutput()
        dlog("render '\(composed)'")
        let attrs: [NSAttributedString.Key: Any] = [.underlineStyle: NSUnderlineStyle.single.rawValue]
        client.setMarkedText(NSAttributedString(string: composed, attributes: attrs),
                             selectionRange: NSRange(location: (composed as NSString).length, length: 0),
                             replacementRange: MixKeyInputController.notFound)

        let start = pageStart
        let page = candidates.dropFirst(start).prefix(pageSize)
        let items: [CandidateView.Item] = page.enumerated().map { i, c in
            let text = s(c.display)
            var badge: String?
            switch c.kind {
            case .ai: badge = "✨ AI"
            case .english: badge = "ABC"
            default: badge = nil
            }
            return CandidateView.Item(number: i + 1, text: text, reading: shared.reading(text), badge: badge)
        }
        var status = (script == .traditional ? "繁體" : "简体") + (Settings.shared.scriptMode == .auto ? " auto (\(scriptReason))" : "")
        if AIAssist.shared.isAvailable {
            status += aiPendingFor != nil ? "  ·  ✨ AI thinking…" : "  ·  ✨ AI on"
        }
        status += "  ·  Enter ✓  Space×2 ✓  Esc ✕"
        if candidates.count > pageSize { status += "  ·  \(start / pageSize + 1)/\((candidates.count + pageSize - 1) / pageSize)" }
        let model = CandidatePanel.Model(preview: composed, items: items, highlighted: highlighted - start, status: status)
        shared.panel.show(model, cursorRect: cursorRect(client))
    }

    private func cursorRect(_ client: IMKTextInput & NSObjectProtocol) -> NSRect {
        var rect = NSRect.zero
        client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        if rect == .zero || (rect.origin.x == 0 && rect.origin.y == 0) {
            let m = NSEvent.mouseLocation
            rect = NSRect(x: m.x, y: m.y - 20, width: 1, height: 20)
        }
        return rect
    }

    private func flashStatus(_ text: String) {
        guard let client = cl() else { return }
        let model = CandidatePanel.Model(preview: text, items: [], highlighted: 0, status: "")
        shared.panel.show(model, cursorRect: cursorRect(client))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if self?.isComposing == false { self?.shared.panel.hide() }
        }
    }

    // MARK: - Script

    private func detectScript() {
        lastDetect = Date()
        switch Settings.shared.scriptMode {
        case .simplified: script = .simplified; scriptReason = "fixed"
        case .traditional: script = .traditional; scriptReason = "fixed"
        case .auto:
            let r = shared.detector?.detect(client: cl(), fallback: Settings.shared.defaultScript)
            script = r?.script ?? Settings.shared.defaultScript
            scriptReason = r?.reason ?? "default"
        }
    }

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
        m.addItem(item("Bigger text", #selector(menuBigger(_:))))
        m.addItem(item("Smaller text", #selector(menuSmaller(_:))))
        m.addItem(.separator())
        let hasKey = Settings.shared.apiKey != nil
        m.addItem(item(hasKey ? "✨ AI assist (Claude)" : "✨ AI assist (add API key first)", #selector(menuToggleAI(_:)),
                       on: hasKey && Settings.shared.aiEnabled))
        m.addItem(item(hasKey ? "Change Claude API key…" : "Add Claude API key…", #selector(menuAPIKey(_:))))
        m.addItem(.separator())
        m.addItem(item(ScriptDetector.hasAccessibility ? "Website detection: allowed ✓" : "Allow website detection (Accessibility)…",
                       #selector(menuAccessibility(_:))))
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
    @objc func menuBigger(_ sender: Any?) { Settings.shared.fontSize = min(40, Settings.shared.fontSize + 2) }
    @objc func menuSmaller(_ sender: Any?) { Settings.shared.fontSize = max(13, Settings.shared.fontSize - 2) }
    @objc func menuToggleAI(_ sender: Any?) {
        if Settings.shared.apiKey == nil { menuAPIKey(sender); return }
        Settings.shared.aiEnabled.toggle()
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

/// Debug logging to ~/Library/Logs/MixKey.log: `defaults write com.mixkey.inputmethod.MixKey debug -bool YES`.
func dlog(_ msg: @autoclosure () -> String) {
    guard UserDefaults.standard.bool(forKey: "debug") else { return }
    let line = "\(ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withFractionalSeconds])) \(msg())\n"
    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/MixKey.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}
