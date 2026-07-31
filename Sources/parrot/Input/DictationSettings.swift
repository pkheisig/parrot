import CoreGraphics
import Foundation

enum ActivationMode: String, CaseIterable {
    case hold
    case toggle

    var displayName: String {
        switch self {
        case .hold: "Hold"
        case .toggle: "Toggle"
        }
    }
}

enum TranscriptionLanguage: String, CaseIterable, Codable {
    case automatic
    case english
    case german

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .english: "English"
        case .german: "German"
        }
    }

    var languageCode: String? {
        switch self {
        case .automatic: nil
        case .english: "en"
        case .german: "de"
        }
    }
}

struct HotkeyShortcut: Codable, Equatable {
    let keyCode: CGKeyCode
    let modifiersRawValue: UInt64
    let isModifierOnly: Bool

    static let fn = HotkeyShortcut(
        keyCode: 63,
        modifiersRawValue: CGEventFlags.maskSecondaryFn.rawValue,
        isModifierOnly: true
    )

    var modifiers: CGEventFlags {
        CGEventFlags(rawValue: modifiersRawValue)
    }

    var displayName: String {
        if isModifierOnly {
            return Self.modifierName(keyCode: keyCode)
        }

        let prefix = Self.modifierSymbols(for: modifiers)
        return prefix + Self.keyName(keyCode: keyCode)
    }

    private static func modifierSymbols(for flags: CGEventFlags) -> String {
        var result = ""
        if flags.contains(.maskControl) { result += "⌃" }
        if flags.contains(.maskAlternate) { result += "⌥" }
        if flags.contains(.maskShift) { result += "⇧" }
        if flags.contains(.maskCommand) { result += "⌘" }
        if flags.contains(.maskSecondaryFn) { result += "fn " }
        return result
    }

    private static func modifierName(keyCode: CGKeyCode) -> String {
        switch keyCode {
        case 54: "Right Command"
        case 55: "Left Command"
        case 56: "Left Shift"
        case 57: "Caps Lock"
        case 58: "Left Option"
        case 59: "Left Control"
        case 60: "Right Shift"
        case 61: "Right Option"
        case 62: "Right Control"
        case 63: "fn"
        default: "Modifier"
        }
    }

    private static func keyName(keyCode: CGKeyCode) -> String {
        let names: [CGKeyCode: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 49: "Space", 50: "`", 51: "⌫",
            53: "Esc", 65: ".", 67: "*", 69: "+", 71: "Clear", 75: "/",
            76: "↩", 78: "-", 81: "=", 82: "0", 83: "1", 84: "2", 85: "3",
            86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10",
            111: "F12", 113: "F15", 115: "Home", 116: "Page Up",
            117: "⌦", 118: "F4", 119: "End", 120: "F2", 121: "Page Down",
            122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }
}

final class DictationSettings {
    private enum Key {
        static let shortcut = "dictationShortcut"
        static let activationMode = "activationMode"
        static let transcriptionLanguage = "transcriptionLanguage"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        if let defaults {
            self.defaults = defaults
        } else {
            // Keep preferences in the original suite so the clean app identity
            // introduced in 0.2 does not discard an existing hotkey or mode.
            self.defaults = UserDefaults(suiteName: AppIdentity.preferencesSuite) ?? .standard
        }
    }

    var shortcut: HotkeyShortcut {
        get {
            guard let data = defaults.data(forKey: Key.shortcut),
                  let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
            else { return .fn }
            return shortcut
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.shortcut)
        }
    }

    var activationMode: ActivationMode {
        get {
            guard let rawValue = defaults.string(forKey: Key.activationMode),
                  let mode = ActivationMode(rawValue: rawValue)
            else { return .hold }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.activationMode)
        }
    }

    var transcriptionLanguage: TranscriptionLanguage {
        get {
            guard let rawValue = defaults.string(forKey: Key.transcriptionLanguage),
                  let language = TranscriptionLanguage(rawValue: rawValue)
            else { return .automatic }
            return language
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.transcriptionLanguage)
        }
    }
}
