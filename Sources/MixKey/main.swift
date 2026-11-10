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
