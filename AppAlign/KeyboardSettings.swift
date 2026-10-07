import Carbon.HIToolbox
import Foundation

struct KeyboardShortcut: Equatable, Hashable, Sendable {
    var keyCode: UInt16
    /// AppAlign-specific Shift/Control/Option/Command bits; Carbon masks never enter storage.
    var modifiers: UInt32

    var hasRequiredModifier: Bool {
        modifiers != 0 && modifiers & ~Self.supportedModifiers == 0
    }

    var isValid: Bool { keyCode <= 127 && hasRequiredModifier }

    static let shift: UInt32 = 1 << 0
    static let control: UInt32 = 1 << 1
    static let option: UInt32 = 1 << 2
    static let command: UInt32 = 1 << 3
    static let supportedModifiers: UInt32 = shift | control | option | command
    static let defaultModifiers: UInt32 = control | option | command

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers & Self.shift != 0 { result |= UInt32(shiftKey) }
        if modifiers & Self.control != 0 { result |= UInt32(controlKey) }
        if modifiers & Self.option != 0 { result |= UInt32(optionKey) }
        if modifiers & Self.command != 0 { result |= UInt32(cmdKey) }
        return result
    }
}

struct KeyboardSettings: Equatable, Sendable {
    var isEnabled = false
    var mode: NavigationMode = .position
    var cyclesAtEdges = true
    var shortcuts: [KeyboardSnapAction: KeyboardShortcut] = Self.defaultShortcuts

    static let defaultShortcuts: [KeyboardSnapAction: KeyboardShortcut] = {
        var result: [KeyboardSnapAction: KeyboardShortcut] = [:]
        let numberKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for index in 0 ..< numberKeyCodes.count {
            result[.zone(ZoneID(rawValue: index))] = KeyboardShortcut(keyCode: numberKeyCodes[index], modifiers: KeyboardShortcut.defaultModifiers)
        }
        result[.direction(.left)] = KeyboardShortcut(keyCode: 123, modifiers: KeyboardShortcut.defaultModifiers)
        result[.direction(.right)] = KeyboardShortcut(keyCode: 124, modifiers: KeyboardShortcut.defaultModifiers)
        result[.direction(.north)] = KeyboardShortcut(keyCode: 126, modifiers: KeyboardShortcut.defaultModifiers)
        result[.direction(.south)] = KeyboardShortcut(keyCode: 125, modifiers: KeyboardShortcut.defaultModifiers)
        result[.next] = KeyboardShortcut(keyCode: 30, modifiers: KeyboardShortcut.defaultModifiers)
        result[.previous] = KeyboardShortcut(keyCode: 33, modifiers: KeyboardShortcut.defaultModifiers)
        result[.restore] = KeyboardShortcut(keyCode: 15, modifiers: KeyboardShortcut.defaultModifiers)
        return result
    }()

    static func decode(from values: [String: PersistedSetting]) -> KeyboardSettings {
        var settings = KeyboardSettings()
        if case .bool(let value) = values["keyboard.enabled"] { settings.isEnabled = value }
        if case .bool(let value) = values["keyboard.cycle"] { settings.cyclesAtEdges = value }
        if case .string(let value) = values["keyboard.mode"], let mode = NavigationMode(rawValue: value) { settings.mode = mode }

        let prefix = "keyboard.shortcut."
        let suffixes = [".key", ".modifiers"]
        for key in values.keys where key.hasPrefix(prefix) {
            guard let suffix = suffixes.first(where: { key.hasSuffix($0) }) else { continue }
            let actionKey = String(key.dropFirst(prefix.count).dropLast(suffix.count))
            guard let action = KeyboardSnapAction(storageKey: actionKey) else { continue }
            var shortcut = settings.shortcuts[action] ?? KeyboardShortcut(keyCode: 0, modifiers: 0)
            switch (suffix, values[key]) {
            case (".key", .integer(let code)) where (0 ... 127).contains(code): shortcut.keyCode = UInt16(code)
            case (".modifiers", .integer(let modifiers)) where modifiers >= 0 && modifiers <= Int(KeyboardShortcut.supportedModifiers): shortcut.modifiers = UInt32(modifiers)
            default: continue
            }
            settings.shortcuts[action] = shortcut
        }
        return settings
    }

    static func managedKeys(in values: [String: PersistedSetting]) -> Set<String> {
        var keys: Set<String> = ["keyboard.enabled", "keyboard.mode", "keyboard.cycle"]
        for key in values.keys where key.hasPrefix("keyboard.shortcut.") {
            let suffix = String(key.dropFirst("keyboard.shortcut.".count))
            let actionKey: String
            if suffix.hasSuffix(".key") { actionKey = String(suffix.dropLast(4)) } else if suffix.hasSuffix(".modifiers") { actionKey = String(suffix.dropLast(10)) } else { continue }
            guard KeyboardSnapAction(storageKey: actionKey) != nil else { continue }
            keys.insert("keyboard.shortcut.\(actionKey).key")
            keys.insert("keyboard.shortcut.\(actionKey).modifiers")
        }
        return keys
    }

    func applying(to values: [String: PersistedSetting]) -> [String: PersistedSetting] {
        var result = values
        for key in Array(values.keys) where key.hasPrefix("keyboard.shortcut.") {
            let suffix = String(key.dropFirst("keyboard.shortcut.".count)).replacingOccurrences(of: ".key", with: "").replacingOccurrences(of: ".modifiers", with: "")
            if KeyboardSnapAction(storageKey: suffix) != nil { result.removeValue(forKey: key) }
        }
        result["keyboard.enabled"] = .bool(isEnabled)
        result["keyboard.mode"] = .string(mode.rawValue)
        result["keyboard.cycle"] = .bool(cyclesAtEdges)
        for (action, shortcut) in shortcuts {
            guard let key = action.storageKey else { continue }
            let prefix = "keyboard.shortcut.\(key)"
            result["\(prefix).key"] = .integer(Int(shortcut.keyCode))
            result["\(prefix).modifiers"] = .integer(Int(shortcut.modifiers))
        }
        return result
    }

    var hasValidShortcuts: Bool {
        let valid = validShortcuts.values
        return valid.count == shortcuts.count && Set(valid).count == valid.count
    }

    var shortcutIssues: [String] {
        var seen: [KeyboardShortcut: KeyboardSnapAction] = [:]
        var issues: [String] = []
        for action in shortcuts.keys.sorted(by: { ($0.storageKey ?? "") < ($1.storageKey ?? "") }) {
            guard let shortcut = shortcuts[action] else { continue }
            if !shortcut.isValid {
                issues.append("\(action.storageDescription) needs a supported key and at least one modifier.")
            } else if let earlier = seen[shortcut] {
                issues.append("\(action.storageDescription) duplicates the shortcut for \(earlier.storageDescription).")
            } else {
                seen[shortcut] = action
            }
        }
        return issues
    }

    var validShortcuts: [KeyboardSnapAction: KeyboardShortcut] {
        var result: [KeyboardSnapAction: KeyboardShortcut] = [:]
        var registered = Set<KeyboardShortcut>()
        for action in shortcuts.keys.sorted(by: { ($0.storageKey ?? "") < ($1.storageKey ?? "") }) {
            guard let shortcut = shortcuts[action], shortcut.isValid, registered.insert(shortcut).inserted else { continue }
            result[action] = shortcut
        }
        return result
    }
}

private extension KeyboardSnapAction {
    var storageKey: String? {
        switch self {
        case .zone(let id): "zone.\(id.rawValue)"
        case .next: "next"
        case .previous: "previous"
        case .direction(let direction): "direction.\(direction.rawValue)"
        case .restore: "restore"
        }
    }

    var storageDescription: String {
        switch self {
        case .zone(let id):
            let suffix = id.rawValue == Int.max || id.rawValue == Int.max - 1 ? " (ID \(id.rawValue))" : ""
            return "Zone \(id.displayNumber)\(suffix)"
        case .next: return "Next zone"
        case .previous: return "Previous zone"
        case .direction(let direction): return direction.rawValue.capitalized
        case .restore: return "Restore"
        }
    }

    init?(storageKey: String) {
        if storageKey == "next" { self = .next; return }
        if storageKey == "previous" { self = .previous; return }
        if storageKey == "restore" { self = .restore; return }
        if storageKey.hasPrefix("zone."), let rawValue = Int(storageKey.dropFirst(5)) {
            self = .zone(ZoneID(rawValue: rawValue))
            return
        }
        if storageKey.hasPrefix("direction."), let direction = NavigationDirection(rawValue: String(storageKey.dropFirst(10))) {
            self = .direction(direction)
            return
        }
        return nil
    }
}
