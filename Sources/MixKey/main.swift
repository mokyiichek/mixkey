import AppKit
import Carbon
import InputMethodKit

/// Registers / enables MixKey as an input source (run by scripts/install.sh).
enum Installer {
    static let bundleID = "com.mixkey.inputmethod.MixKey"
    static let modeID = "com.mixkey.inputmethod.MixKey.PinyinEnglish"

    static func sources() -> [TISInputSource] {
        let props = [kTISPropertyBundleID as String: bundleID] as CFDictionary
        guard let list = TISCreateInputSourceList(props, true)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list
    }

    static func id(_ src: TISInputSource) -> String {
        guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    static func install(select: Bool) {
        let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
        print("register: \(status == noErr ? "ok" : "status \(status)")")
        var found = false
        for src in sources() {
            found = true
            let e = TISEnableInputSource(src)
            print("enable \(id(src)): \(e == noErr ? "ok" : "status \(e)")")
            if select && id(src) == modeID {
                let s = TISSelectInputSource(src)
                print("select \(id(src)): \(s == noErr ? "ok" : "status \(s)")")
            }
        }
        if !found { print("MixKey input source not visible yet — log out and back in, then add it in System Settings › Keyboard › Input Sources.") }
    }

    static func uninstall() {
        for src in sources() {
            let s = TISDisableInputSource(src)
            print("disable \(id(src)): \(s == noErr ? "ok" : "status \(s)")")
        }
    }
}

let args = CommandLine.arguments
// --preview out.png: draw the choice bar in every colour theme (for screenshots / design review)
if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
    let items = [CandidateView.Item(number: 1, text: "你好", reading: nil, badge: nil),
                 CandidateView.Item(number: 2, text: "拟好", reading: nil, badge: nil),
                 CandidateView.Item(number: 3, text: "你", reading: nil, badge: nil),
                 CandidateView.Item(number: 4, text: "泥", reading: nil, badge: nil),
                 CandidateView.Item(number: 5, text: "ni hao", reading: nil, badge: "ABC")]
    let saved = Settings.shared.themeID
    var bars: [(String, NSImage)] = []
    for t in Theme.all {
        Settings.shared.themeID = t.id
        let v = CandidateView()
        v.model = CandidatePanel.Model(items: items, highlighted: -1, hint: "简")
        let size = v.measure()
        v.frame = NSRect(origin: .zero, size: size)
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        rep.size = size
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: size); img.addRepresentation(rep)
        bars.append((t.name, img))
    }
    Settings.shared.themeID = saved
    let w = (bars.map { $0.1.size.width }.max() ?? 300) + 190, rowH: CGFloat = 58
    let canvas = NSImage(size: NSSize(width: w, height: rowH * CGFloat(bars.count) + 20))
    canvas.lockFocus()
    NSColor(white: 0.93, alpha: 1).setFill(); NSRect(origin: .zero, size: canvas.size).fill()
    for (n, (name, img)) in bars.enumerated() {
        let y = canvas.size.height - 10 - rowH * CGFloat(n + 1) + (rowH - img.size.height) / 2
        NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)])
            .draw(at: NSPoint(x: 16, y: y + img.size.height / 2 - 9))
        img.draw(at: NSPoint(x: 170, y: y), from: .zero, operation: .sourceOver, fraction: 1)
    }
    canvas.unlockFocus()
    let tiff = canvas.tiffRepresentation!
    try! NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[i + 1]))
    print("preview written")
    exit(0)
}
if args.contains("--install") {
    Installer.install(select: args.contains("--select"))
    exit(0)
}
if args.contains("--uninstall") {
    Installer.uninstall()
    exit(0)
}

let connection = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String ?? "MixKey_Connection"
let server = IMKServer(name: connection, bundleIdentifier: Bundle.main.bundleIdentifier)
_ = Shared.shared // load the lexicon up front so the first keystroke is fast
NSLog("MixKey started (\(server != nil ? "server ok" : "server FAILED"))")
NSApplication.shared.run()
