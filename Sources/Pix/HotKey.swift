import AppKit
import Carbon

/// The shortcut that calls Pix from anywhere (⌃⌥Space unless changed in Settings). Carbon hot keys
/// need no extra permission.
final class HotKey {
    nonisolated(unsafe) private static var action: ((Bool) -> Void)?  // true on press, false on release
    nonisolated(unsafe) private static var handlerInstalled = false
    private var ref: EventHotKeyRef?

    struct Combo: Equatable {
        var code: UInt32     // virtual key code
        var mods: UInt32     // Carbon modifiers (controlKey | optionKey …)
        var key: String      // "Space", "P", "F5"

        static let standard = Combo(code: UInt32(kVK_Space), mods: UInt32(controlKey | optionKey), key: "Space")

        /// "⌃⌥Space", in the order macOS menus use.
        var symbols: [String] {
            var s: [String] = []
            if mods & UInt32(controlKey) != 0 { s.append("\u{2303}") }
            if mods & UInt32(optionKey) != 0 { s.append("\u{2325}") }
            if mods & UInt32(shiftKey) != 0 { s.append("\u{21E7}") }
            if mods & UInt32(cmdKey) != 0 { s.append("\u{2318}") }
            return s + [key]
        }
        var label: String { symbols.joined() }

        /// For the menu's key equivalent.
        var menuKey: String { key == "Space" ? " " : key.count == 1 ? key.lowercased() : "" }
        var menuMods: NSEvent.ModifierFlags {
            var f: NSEvent.ModifierFlags = []
            if mods & UInt32(controlKey) != 0 { f.insert(.control) }
            if mods & UInt32(optionKey) != 0 { f.insert(.option) }
            if mods & UInt32(shiftKey) != 0 { f.insert(.shift) }
            if mods & UInt32(cmdKey) != 0 { f.insert(.command) }
            return f
        }

        /// A key press as a shortcut, or nil without Control, Option or Command (plain keys are for typing).
        static func from(_ e: NSEvent) -> Combo? {
            let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !f.intersection([.control, .option, .command]).isEmpty else { return nil }
            var m: UInt32 = 0
            if f.contains(.control) { m |= UInt32(controlKey) }
            if f.contains(.option) { m |= UInt32(optionKey) }
            if f.contains(.shift) { m |= UInt32(shiftKey) }
            if f.contains(.command) { m |= UInt32(cmdKey) }
            let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Escape: "Esc",
                                        kVK_LeftArrow: "\u{2190}", kVK_RightArrow: "\u{2192}", kVK_UpArrow: "\u{2191}", kVK_DownArrow: "\u{2193}",
                                        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
            let key = names[Int(e.keyCode)] ?? (e.charactersIgnoringModifiers ?? "").uppercased()
            guard !key.isEmpty, Int(e.keyCode) != kVK_Escape else { return nil }
            return Combo(code: UInt32(e.keyCode), mods: m, key: key)
        }

        static var saved: Combo {
            get {
                let d = UserDefaults.standard
                guard let key = d.string(forKey: "hotkey.key") else { return .standard }
                return Combo(code: UInt32(d.integer(forKey: "hotkey.code")), mods: UInt32(d.integer(forKey: "hotkey.mods")), key: key)
            }
            set {
                let d = UserDefaults.standard
                d.set(Int(newValue.code), forKey: "hotkey.code")
                d.set(Int(newValue.mods), forKey: "hotkey.mods")
                d.set(newValue.key, forKey: "hotkey.key")
            }
        }
    }

    /// `action(true)` when the keys go down, `action(false)` when they come up (a tap opens Pix; holding talks).
    init(action: @escaping (Bool) -> Void) {
        HotKey.action = action
        if !HotKey.handlerInstalled {
            HotKey.handlerInstalled = true
            var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                DispatchQueue.main.async { HotKey.action?(down) }
                return noErr
            }, 2, &specs, nil, nil)
        }
        register(Combo.saved)
    }

    /// Switches to a new shortcut. Returns false if macOS or another app already has it (the old one stays).
    @discardableResult
    func rebind(_ c: Combo) -> Bool {
        let old = Combo.saved
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard register(c) else { register(old); return false }
        Combo.saved = c
        return true
    }

    @discardableResult
    private func register(_ c: Combo) -> Bool {
        let id = EventHotKeyID(signature: OSType(0x5049_5820), id: 1)  // "PIX "
        return RegisterEventHotKey(c.code, c.mods, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    deinit { if let ref { UnregisterEventHotKey(ref) } }
}
