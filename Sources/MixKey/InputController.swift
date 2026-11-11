import AppKit
import InputMethodKit
import MixKeyCore

/// One controller per text-input client.
///
/// Typing model ("feels like normal typing"):
///  - What you type is shown converted, inline (你好, Port Dickson, fixed spelling).
///  - Words are sent to the app automatically as you keep typing; only the last couple of words stay
///    open so the next word can still fix them (ming → 明 becomes 明天 when you type tian).
///  - Enter sends everything AND does what Enter normally does (new line / send message).
///  - A small one-line bar of choices appears only when there's something to choose (Chinese words,
///    or the original spelling of a word that was corrected).
@objc(MixKeyInputController)
final class MixKeyInputController: IMKInputController {
    private var raw = ""                 // what's still open (letters + spaces)
    /// Last bit of text already sent in this run (for spacing). Empty = the run is over (cursor moved, Enter, …).
    private var lead = "" {
        didSet { if lead.isEmpty { recent = ""; lastWord = nil } }
    }
    /// What MixKey typed into this field in the current run, so it can still be fixed afterwards.
    private var recent = ""
    /// The last English word sent with its space, so the next word can still fix it ("sport" + "dickson").
    private var lastWord: (typed: String, sent: String)?
    private var aiFixWork: DispatchWorkItem?
    private var keyCount = 0
    private var candidates: [Candidate] = []
    private var highlighted = 0
    private var userMovedHighlight = false
    private var barVisible = false
    private let pageSize = 9

    private(set) var script: ChineseScript = .simplified
    private var scriptReason = ""
    private var capitalizeFirst = false
    private var lastSentChinese = false
    private var lastDetect = Date.distantPast
    private var aiWork: DispatchWorkItem?

    /// The last spelling fix that was sent ("because " for "becuase"), so Delete can undo it.
    private var lastFix: (sent: String, typed: String)?

    private var shiftAlone = false
    private var shiftDownAt = Date.distantPast

    /// The text field we're typing into. IMK passes it with every call; `client()` can be nil in
    /// Chrome / Electron apps, so remember the one we were given.
    private weak var activeClient: (IMKTextInput & NSObjectProtocol)?
    func cl() -> (IMKTextInput & NSObjectProtocol)? {
        activeClient ?? (super.client() as (IMKTextInput & NSObjectProtocol)?)
    }
    private func adopt(_ sender: Any?) {
        if let c = sender as? (IMKTextInput & NSObjectProtocol) { activeClient = c }
    }

    private var shared: Shared { .shared }
    private var engine: MixEngine? { shared.engine }
    private var isComposing: Bool { !raw.isEmpty }

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
        dlog("activate \(cl()?.bundleIdentifier() ?? "nil")")
        lead = ""
        detectScript()
        AIAssist.shared.warmUp()
        shared.panel.onSelect = { [weak self] i in
            guard let self = self else { return }
            self.select(self.pageStart + i)
        }
    }

    override func deactivateServer(_ sender: Any!) {
        adopt(sender)
        if isComposing { sendAll() }
        shared.panel.hide()
        lead = ""
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        adopt(sender)
        if isComposing { sendAll() }
        lead = ""
    }

    // MARK: - Keys

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        let t0 = Date()
        defer {
            let ms = Date().timeIntervalSince(t0) * 1000
            if ms > 60 { dlog(String(format: "SLOW key %.0f ms (analyze %.0f, render %.0f, start %.0f)", ms, tAnalyze, tRender, tStart)) }
            tAnalyze = 0; tRender = 0; tStart = 0
        }
        adopt(sender)
        guard let event = event else { return false }
        if event.type == .flagsChanged {
            handleShift(event)
            return false
        }
        guard event.type == .keyDown else { return false }
        shiftAlone = false
        let fix = lastFix
        lastFix = nil
        keyCount += 1
        aiFixWork?.cancel()
        dlog("key \(event.keyCode) '\(event.characters ?? "")' raw='\(raw)' client=\(cl() == nil ? "nil" : "ok")")

        guard engine != nil, cl() != nil else { return false }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if !mods.isEmpty || shared.englishMode {
            if isComposing { sendAll() }
            lead = ""
            return false
        }

        let chars = event.characters ?? ""
        switch event.keyCode {
        case 36, 76: // Return / Enter
            guard isComposing else { lead = ""; return false }
            if event.modifierFlags.contains(.shift) { sendLiteral(); return true }
            if userMovedHighlight && barVisible { select(highlighted); return true }
            sendAll()
            lead = ""
            return false // let the app do its Enter (new line / send)
        case 53: // Esc: throw away what's still open
            guard isComposing else { return false }
            reset()
            return true
        case 51: // Delete
            guard isComposing else {
                if undoFix(fix) { return true }
                lead = ""
                return false
            }
            raw.removeLast()
            if raw.isEmpty { reset() } else { refresh(autoSend: false) }
            return true
        case 49: // Space
            guard isComposing else {
                if !lead.isEmpty { recent += " " }
                lead = " "
                return false
            }
            if raw.hasSuffix(" ") {
                sendAll(trailingSpace: true) // double space: send + a real space
            } else {
                raw += " "
                refresh()
            }
            return true
        case 48: // Tab / Shift+Tab: move through choices
            guard isComposing, barVisible else { if isComposing { sendAll() }; return false }
            moveHighlight(event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case 125, 126: // Down / Up
            guard isComposing, barVisible else { if isComposing { sendAll() }; lead = ""; return false }
            moveHighlight(event.keyCode == 125 ? 1 : -1)
            return true
        case 123, 124, 115, 119, 116, 121: // arrows, Home/End, Page keys: send and move
            if isComposing { sendAll() }
            lead = ""
            return false
        default:
            break
        }

        guard chars.count == 1, let c = chars.first else {
            if isComposing { sendAll() }
            lead = ""
            return false
        }

        if c.isASCII && c.isLetter {
            if !isComposing { startComposition() }
            raw.append(c)
            refresh()
            return true
        }
        if c == "'" && isComposing && !raw.hasSuffix(" ") {
            raw.append(c)
            refresh()
            return true
        }
        if let d = c.wholeNumberValue, c.isASCII, isComposing, barVisible {
            if d >= 1 { select(pageStart + d - 1) }
            return true
        }
        if let full = MixKeyInputController.fullWidth[c] {
            if isComposing {
                let out = sendAll()
                let chinese = out.last.map { ScriptConverter.isCJK($0) } ?? false
                insert(chinese ? full : String(c))
                lead = ""
                return true
            }
            if lastSentChinese && ",.?!;:\\".contains(c) {
                insert(full)
                return true
            }
            return false
        }
        // Any other key (digits, symbols): send what we have, then let the app handle the key.
        if isComposing { sendAll(trailingSpace: raw.hasSuffix(" ")) }
        lead = ""
        lastSentChinese = false
        return false
    }

    private func handleShift(_ event: NSEvent) {
        guard event.keyCode == 56 || event.keyCode == 60 else { shiftAlone = false; return }
        if event.modifierFlags.contains(.shift) {
            shiftAlone = true
            shiftDownAt = Date()
        } else if shiftAlone, Date().timeIntervalSince(shiftDownAt) < 0.4 {
            shiftAlone = false
            if isComposing { sendLiteral() }
            shared.englishMode.toggle()
            flash(shared.englishMode ? "ABC" : "混")
        }
    }

    // MARK: - Composition

    private func startComposition() {
        let ts = Date()
        defer { tStart += Date().timeIntervalSince(ts) * 1000 }
        if Settings.shared.scriptMode == .auto, Date().timeIntervalSince(lastDetect) > 4 { detectScript() }
        capitalizeFirst = false
        guard lead.isEmpty || lead == " ", Settings.shared.capitalizeSentences, let c = cl() else { return }
        if MixKeyInputController.codeApps.contains(c.bundleIdentifier() ?? "") { return }
        let sel = c.selectedRange()
        guard sel.location != NSNotFound else { return }
        if sel.location == 0 { capitalizeFirst = true; return }
        let start = max(0, sel.location - 20)
        var actual = NSRange(location: NSNotFound, length: 0)
        let before = c.string(from: NSRange(location: start, length: sel.location - start), actualRange: &actual) ?? ""
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        if let last = trimmed.last {
            capitalizeFirst = ".!?。！？\n".contains(last)
        } else {
            capitalizeFirst = start == 0 && !before.isEmpty
        }
    }

    private var options: EngineOptions {
        var o = EngineOptions()
        o.spaceBetweenScripts = Settings.shared.spaceBetweenScripts
        o.capitalizeFirst = capitalizeFirst
        return o
    }

    private func s(_ text: String) -> String {
        script == .traditional ? (engine?.script.toTraditional(text) ?? text) : text
    }

    /// `text` with the right spacing after what was already sent in this run.
    private func withLead(_ text: String) -> String {
        guard let engine = engine, !lead.isEmpty, !text.isEmpty else { return text }
        return String(engine.join(lead, text, options: options).dropFirst(lead.count))
    }

    private func refresh(autoSend: Bool = true) {
        guard let engine = engine else { return }
        engine.fixSpelling = Settings.shared.autoFixSpelling
        if raw.trimmingCharacters(in: .whitespaces).isEmpty { reset(); return }
        let ta = Date()
        var a = engine.analyze(raw, options: options)
        tAnalyze += Date().timeIntervalSince(ta) * 1000

        // Send settled words. Keep open: the word being typed, plus the word before it when it can
        // still change (Chinese, or the start of a name like "port" -> Port Dickson).
        // English words go out the moment you press space.
        let n = autoSend ? engine.settledCount(a) : 0
        if n > 0, a.segments[n - 1].end < raw.count || raw.hasSuffix(" ") {
            let done = Array(a.segments.prefix(n))
            var text = ""
            for seg in done { text = engine.join(text, seg.output, options: options) }
            learnSent(done)
            if capitalizeFirst, let f = text.first, f.isLowercase, f.isASCII { text = f.uppercased() + text.dropFirst() }
            // keep the space you typed after the next word (only leading spaces go)
            let rest = String(String(raw.dropFirst(done.last!.end)).drop(while: { $0 == " " }))
            // an English word you finished with space: the space shows straight away, like normal typing
            let finished = rest.isEmpty && raw.hasSuffix(" ") && done.last!.kind == .english
            let typed = String(Array(raw)[done.last!.start..<done.last!.end])
            let single = finished && done.count == 1
            let previous = lastWord
            if single, let prev = previous, let name = engine.nameAcross(prev.typed, typed),
               clearMarked(), replaceTail(prev.sent, with: name + " ") {
                // "sport" was already sent; with "dickson" it is clearly Port Dickson: fix both
                lastFix = (sent: name + " ", typed: prev.sent + typed)
            } else {
                send(s(text) + (finished ? " " : ""))
                lastWord = nil
                if single {
                    lastWord = (typed: typed, sent: done[0].output + " ")
                    // remember a spelling fix so Delete can undo it
                    if done[0].output.lowercased() != typed.lowercased() {
                        lastFix = (sent: done[0].output + " ", typed: typed)
                    }
                }
            }
            if finished { scheduleAIFix() }
            raw = rest
            capitalizeFirst = false
            if raw.isEmpty { reset(); return }
            a = engine.analyze(raw, options: options)
        }

        // Choices: Chinese words for the first Chinese part; otherwise the original spelling if we changed it.
        var list: [Candidate] = []
        let key = raw.trimmingCharacters(in: .whitespaces)
        if let ai = AIAssist.shared.cached(key), AIAssist.shared.isAvailable, ai != a.preview {
            list.append(Candidate(display: ai, output: ai, consumes: raw.count, kind: .ai))
        }
        if a.hasChinese, let fi = a.segments.firstIndex(where: { $0.kind == .chinese }) {
            // Choice 1 is always what you see inline for the first Chinese part.
            let seg = a.segments[fi]
            var before = ""
            for x in a.segments[..<fi] { before = engine.join(before, x.output, options: options) }
            let out = before.isEmpty ? seg.output : engine.join(before, seg.output, options: options)
            list.append(Candidate(display: seg.output, output: out, consumes: seg.end, kind: .word, reading: seg.reading))
            for c in a.candidates where (c.kind == .word || c.kind == .alternative)
                && !(c.display == seg.output && c.consumes == seg.end) {
                list.append(c)
            }
            if let eng = a.candidates.first(where: { $0.kind == .english }) { list.append(eng) }
        } else if let eng = a.candidates.first(where: { $0.kind == .english }), eng.output != a.preview {
            list.append(Candidate(display: eng.display, output: eng.output, consumes: raw.count, kind: .english))
            if a.tokens.contains(where: { $0.ambiguous }), let alt = a.candidates.first(where: { $0.kind == .alternative }) {
                list.append(alt)
            }
        } else if a.tokens.contains(where: { $0.ambiguous }), let alt = a.candidates.first(where: { $0.kind == .alternative }) {
            list.append(alt)
        }
        current = a
        candidates = list
        highlighted = 0
        userMovedHighlight = false
        render()
        scheduleAI(a)
    }

    private var current: Analysis?
    private var tAnalyze = 0.0, tRender = 0.0, tStart = 0.0

    private var preview: String {
        if userMovedHighlight, candidates.indices.contains(highlighted), candidates[highlighted].consumes >= raw.count {
            return s(candidates[highlighted].output)
        }
        if let ai = AIAssist.shared.cached(raw.trimmingCharacters(in: .whitespaces)), AIAssist.shared.isAvailable { return s(ai) }
        return s(current?.preview ?? raw)
    }

    private func scheduleAI(_ a: Analysis) {
        aiWork?.cancel()
        let key = raw.trimmingCharacters(in: .whitespaces)
        guard AIAssist.shared.isAvailable, AIAssist.shared.cached(key) == nil, a.tokens.count >= 2 else { return }
        let guess = a.preview
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.raw.trimmingCharacters(in: .whitespaces) == key else { return }
            AIAssist.shared.convert(raw: key, localGuess: guess) { [weak self] result in
                guard let self = self, result != nil, self.raw.trimmingCharacters(in: .whitespaces) == key else { return }
                self.refresh(autoSend: false)
            }
        }
        aiWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private var pageStart: Int { (highlighted / pageSize) * pageSize }

    private func moveHighlight(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        highlighted = max(0, min(candidates.count - 1, highlighted + delta))
        userMovedHighlight = true
        render()
    }

    private func select(_ index: Int) {
        guard candidates.indices.contains(index) else { return }
        let c = candidates[index]
        if c.kind == .word, let reading = c.reading {
            engine?.learn(reading: reading, word: c.display, picked: true)
        }
        if c.consumes >= raw.count {
            send(s(c.output))
            reset(clearMarked: false)
        } else {
            send(s(c.output))
            raw = String(raw.dropFirst(c.consumes)).trimmingCharacters(in: .whitespaces)
            capitalizeFirst = false
            if raw.isEmpty { reset(clearMarked: false) } else { refresh(autoSend: false) }
        }
    }

    // MARK: - Sending text

    /// Sends everything that's open. Returns what was sent.
    @discardableResult
    private func sendAll(trailingSpace: Bool = false) -> String {
        guard isComposing else { return "" }
        var out = preview
        // The last word is finished now: let it get its spelling fix too, as long as nothing
        // switches between Chinese and English (what you saw is what you get).
        if !userMovedHighlight, !raw.hasSuffix(" "), let engine = engine, let shown = current {
            let done = engine.analyze(raw + " ", options: options)
            if done.tokens.map(\.kind) == shown.tokens.map(\.kind), AIAssist.shared.cached(raw.trimmingCharacters(in: .whitespaces)) == nil {
                out = s(done.preview)
                learnSent(done.segments)
            }
        }
        if trailingSpace, let l = out.last, l.isASCII, l.isLetter || l.isNumber { out += " " }
        send(out)
        reset(clearMarked: false)
        return out
    }

    /// Chinese phrases sent without changes are probably right: give them a gentle boost.
    private func learnSent(_ segs: [Segment]) {
        guard let engine = engine else { return }
        for seg in segs where seg.kind == .chinese {
            guard let r = seg.reading, (2...6).contains(r.split(separator: " ").count) else { continue }
            engine.learn(reading: r, word: seg.output, picked: false)
        }
    }

    /// Delete straight after a word was fixed: put back what you typed, and don't fix that word again.
    private func undoFix(_ fix: (sent: String, typed: String)?) -> Bool {
        guard let fix = fix, let c = cl() else { return false }
        let sel = c.selectedRange()
        let len = (fix.sent as NSString).length
        guard sel.location != NSNotFound, sel.length == 0, sel.location >= len else { return false }
        let range = NSRange(location: sel.location - len, length: len)
        var actual = NSRange(location: NSNotFound, length: 0)
        guard c.string(from: range, actualRange: &actual) == fix.sent else { return false }
        c.insertText(fix.typed, replacementRange: range)
        lead = ""
        if !fix.typed.contains(" ") { shared.keep(fix.typed.lowercased()) }
        return true
    }

    /// Removes the underlined text being typed (so the text before the cursor is what was sent).
    private func clearMarked() -> Bool {
        cl()?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: MixKeyInputController.notFound)
        return true
    }

    /// Replaces text MixKey just typed (right before the cursor) — only if it is really still there.
    @discardableResult
    private func replaceTail(_ old: String, with new: String) -> Bool {
        guard let c = cl(), recent.hasSuffix(old) else { return false }
        let sel = c.selectedRange()
        let len = (old as NSString).length
        guard sel.location != NSNotFound, sel.length == 0, sel.location >= len else { return false }
        let range = NSRange(location: sel.location - len, length: len)
        var actual = NSRange(location: NSNotFound, length: 0)
        guard c.string(from: range, actualRange: &actual) == old else { return false }
        cachedRect = nil
        c.insertText(new, replacementRange: range)
        recent = String(recent.dropLast(old.count)) + new
        lastWord = nil
        if let l = new.last { lead = String(l) }
        return true
    }

    // MARK: - AI fix

    /// A moment after you stop typing, Claude checks the sentence you just typed and fixes what the
    /// dictionary missed. Only that sentence is sent. Press Delete straight away to undo.
    private func scheduleAIFix() {
        aiFixWork?.cancel()
        guard AIAssist.shared.isAvailable else { return }
        let stamp = keyCount
        let work = DispatchWorkItem { [weak self] in self?.runAIFix(stamp) }
        aiFixWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func runAIFix(_ stamp: Int) {
        guard stamp == keyCount, !isComposing else { return }
        // the last sentence MixKey typed
        let ends: Set<Character> = [".", "!", "?", "。", "！", "？", "\n"]
        var tail = recent
        if let i = tail.lastIndex(where: { ends.contains($0) }) { tail = String(tail[tail.index(after: i)...]) }
        let sentence = String(tail.drop(while: { $0 == " " }))
        let words = sentence.split(separator: " ").count
        guard words >= 3, sentence.count <= 300, sentence.contains(where: { $0.isASCII && $0.isLetter }) else { return }
        AIAssist.shared.fixSentence(sentence) { [weak self] fixed in
            guard let self = self, var fixed = fixed, stamp == self.keyCount, !self.isComposing else { return }
            let trailing = String(sentence.reversed().prefix(while: { $0 == " " }))
            fixed = fixed.trimmingCharacters(in: .whitespaces) + trailing
            guard fixed != sentence, abs(fixed.split(separator: " ").count - words) <= 2 else { return }
            if self.replaceTail(sentence, with: fixed) {
                self.lastFix = (sent: fixed, typed: sentence)
                self.flash("✨")
            }
        }
    }

    /// Shift+Enter: send exactly what was typed.
    private func sendLiteral() {
        send(raw.trimmingCharacters(in: .whitespaces))
        reset(clearMarked: false)
    }

    private func send(_ text: String) {
        guard !text.isEmpty else { return }
        let t = withLead(text)
        insert(t)
        lead = String(t.suffix(1))
        lastSentChinese = t.last.map { ScriptConverter.isCJK($0) } ?? false
    }

    private func insert(_ text: String) {
        cachedRect = nil
        recent += text
        if recent.count > 400 { recent = String(recent.suffix(300)) }
        cl()?.insertText(text, replacementRange: MixKeyInputController.notFound)
    }

    private func reset(clearMarked: Bool = true) {
        cachedRect = nil
        raw = ""
        candidates = []
        current = nil
        highlighted = 0
        userMovedHighlight = false
        aiWork?.cancel()
        if clearMarked {
            cl()?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                replacementRange: MixKeyInputController.notFound)
        }
        barVisible = false
        shared.panel.hide()
    }

    // MARK: - Drawing

    private func render() {
        let tr = Date()
        defer { tRender += Date().timeIntervalSince(tr) * 1000 }
        guard let client = cl() else { return }
        let composed = withLead(preview)
        client.setMarkedText(NSAttributedString(string: composed, attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]), selectionRange: NSRange(location: (composed as NSString).length, length: 0),
            replacementRange: MixKeyInputController.notFound)

        guard !candidates.isEmpty else {
            barVisible = false
            shared.panel.hide()
            return
        }
        let start = pageStart
        let items: [CandidateView.Item] = candidates.dropFirst(start).prefix(pageSize).enumerated().map { i, c in
            let text = s(c.display)
            let badge: String? = c.kind == .ai ? "✨" : (c.kind == .english ? "ABC" : nil)
            return CandidateView.Item(number: i + 1, text: text,
                                      reading: Settings.shared.showPinyin ? shared.reading(text) : nil, badge: badge)
        }
        var hint = script == .traditional ? "繁" : "简"
        if candidates.count > pageSize { hint += " \(start / pageSize + 1)/\((candidates.count + pageSize - 1) / pageSize)" }
        let model = CandidatePanel.Model(items: items, highlighted: userMovedHighlight ? highlighted - start : -1, hint: hint,
                                         firstIsCurrent: current?.hasChinese == true && start == 0)
        barVisible = true
        shared.panel.show(model, cursorRect: cursorRect(client))
    }

    /// Where the open text starts on screen. It doesn't move while you type a word, so ask the app once.
    private var cachedRect: NSRect?

    private func cursorRect(_ client: IMKTextInput & NSObjectProtocol) -> NSRect {
        if let r = cachedRect { return r }
        var rect = NSRect.zero
        client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        if rect == .zero || (rect.origin.x == 0 && rect.origin.y == 0) {
            let m = NSEvent.mouseLocation
            rect = NSRect(x: m.x, y: m.y - 20, width: 1, height: 20)
        }
        cachedRect = rect
        return rect
    }

    private func flash(_ text: String) {
        guard let client = cl() else { return }
        shared.panel.show(CandidatePanel.Model(items: [CandidateView.Item(number: 0, text: text, reading: nil, badge: nil)],
                                               highlighted: 0, hint: ""), cursorRect: cursorRect(client))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            if self?.isComposing == false { self?.shared.panel.hide() }
        }
    }

    // MARK: - Script

    func detectScript() {
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
}
