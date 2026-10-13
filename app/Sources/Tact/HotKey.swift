import Carbon.HIToolbox

/// A Carbon global hotkey. The controller registers it only while a chat tool
/// is frontmost, so the key combination keeps working normally in other apps.
final class HotKey {
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Parses specs like "option+space", "ctrl+shift+g", "cmd+option+/".
    init?(spec: String) {
        var mods: UInt32 = 0
        var key: UInt32?
        var parts: [String] = []
        let tokens = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        for token in tokens {
            switch token {
            case "cmd", "command", "⌘":
                mods |= UInt32(cmdKey); parts.append("⌘")
            case "opt", "option", "alt", "⌥":
                mods |= UInt32(optionKey); parts.append("⌥")
            case "ctrl", "control", "⌃":
                mods |= UInt32(controlKey); parts.append("⌃")
            case "shift", "⇧":
                mods |= UInt32(shiftKey); parts.append("⇧")
            default:
                guard key == nil, let code = HotKey.keyCodes[token] else { return nil }
                key = UInt32(code)
                parts.append(token == "space" ? "Space" : token.uppercased())
            }
        }
        guard let k = key, mods != 0 else { return nil }
        keyCode = k
        modifiers = mods
        display = parts.joined()
    }

    /// Installs the Carbon event handler once. The handler runs on the main
    /// thread.
    func installHandler() -> Bool {
        if handlerRef != nil { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                hotKey.onPress?()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        return status == noErr
    }

    /// The Carbon handler holds an unretained pointer to this object, so it
    /// must go away with it (the settings window can replace the hotkey).
    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let handler = handlerRef { RemoveEventHandler(handler) }
    }

    func register() -> OSStatus {
        if hotKeyRef != nil { return noErr }
        let id = EventHotKeyID(signature: OSType(0x4752_504C), id: 1) // "GRPL"
        return RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    static let keyCodes: [String: Int] = [
        "space": kVK_Space, "tab": kVK_Tab, "return": kVK_Return, "enter": kVK_Return,
        "/": kVK_ANSI_Slash, ".": kVK_ANSI_Period, ",": kVK_ANSI_Comma, ";": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, "\\": kVK_ANSI_Backslash, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "`": kVK_ANSI_Grave,
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]
}
