import Carbon.HIToolbox
import XCTest

final class KeyboardSettingsTests: XCTestCase {
    func testDefaultBindingsUseDistinctPhysicalKeysAndModifierBits() {
        let settings = KeyboardSettings()
        let numberCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        XCTAssertEqual(numberCodes.indices.map { settings.shortcuts[.zone(ZoneID(rawValue: $0))]?.keyCode }, numberCodes.map(Optional.some))
        XCTAssertEqual(settings.shortcuts[.zone(ZoneID(rawValue: 0))]?.modifiers, KeyboardShortcut.control | KeyboardShortcut.option | KeyboardShortcut.command)
        XCTAssertEqual(settings.shortcuts[.direction(.left)]?.carbonModifiers, UInt32(controlKey | optionKey | cmdKey))
        XCTAssertEqual(settings.shortcuts[.direction(.north)]?.keyCode, 126)
    }

    func testTypedSettingsRoundTripPreservesUnknownKeysAndHandlesMaximumZoneID() {
        let unknown: [String: PersistedSetting] = [
            "other.feature.flag": .bool(true),
            "keyboard.future.option": .string("preserve"),
            "keyboard.shortcut.zone.9223372036854775807.key": .integer(42),
            "keyboard.shortcut.zone.9223372036854775807.modifiers": .integer(Int(KeyboardShortcut.command))
        ]
        let decoded = KeyboardSettings.decode(from: unknown)
        let shortcut = decoded.shortcuts[.zone(ZoneID(rawValue: Int.max))]
        XCTAssertEqual(shortcut?.keyCode, 42)
        XCTAssertEqual(shortcut?.modifiers, KeyboardShortcut.command)
        let saved = decoded.applying(to: unknown)
        XCTAssertEqual(saved["other.feature.flag"], .bool(true))
        XCTAssertEqual(saved["keyboard.future.option"], .string("preserve"))
        XCTAssertEqual(saved["keyboard.shortcut.zone.9223372036854775807.key"], .integer(42))
    }

    func testInvalidTypedBindingFallsBackForKnownActionAndDoesNotBlockOtherSettings() {
        let malformed: [String: PersistedSetting] = [
            "keyboard.enabled": .bool(false),
            "keyboard.shortcut.zone.0.key": .string("not an integer"),
            "keyboard.shortcut.zone.0.modifiers": .string("not an integer")
        ]
        let decoded = KeyboardSettings.decode(from: malformed)
        XCTAssertEqual(decoded.shortcuts[.zone(ZoneID(rawValue: 0))]?.keyCode, 18)
        XCTAssertTrue(decoded.hasValidShortcuts)
        var changed = decoded
        changed.isEnabled = true
        XCTAssertTrue(changed.isEnabled)
        XCTAssertEqual(ZoneID(rawValue: Int.max).displayNumber, String(Int.max))
        XCTAssertEqual(ZoneID(rawValue: Int.max - 1).displayNumber, String(Int.max))
    }

    func testInvalidAndDuplicateBindingsHaveActionSpecificDiagnostics() {
        var settings = KeyboardSettings()
        settings.shortcuts[.zone(ZoneID(rawValue: 0))] = KeyboardShortcut(keyCode: 128, modifiers: 0)
        settings.shortcuts[.zone(ZoneID(rawValue: 1))] = settings.shortcuts[.next]
        XCTAssertFalse(settings.hasValidShortcuts)
        XCTAssertEqual(settings.shortcutIssues.count, 2)
        XCTAssertTrue(settings.shortcutIssues[0].contains("Zone 1"))
        XCTAssertTrue(settings.shortcutIssues[1].contains("Zone 2"))
    }

    func testRemovingKnownShortcutPreservesUnknownKeyboardNamespaceKeys() {
        var settings = KeyboardSettings()
        settings.shortcuts.removeValue(forKey: .zone(ZoneID(rawValue: 0)))
        let values: [String: PersistedSetting] = [
            "keyboard.shortcut.zone.0.key": .integer(18),
            "keyboard.shortcut.zone.0.modifiers": .integer(14),
            "keyboard.future.setting": .string("preserve"),
            "other.feature.flag": .bool(true)
        ]
        let saved = settings.applying(to: values)
        XCTAssertNil(saved["keyboard.shortcut.zone.0.key"])
        XCTAssertNil(saved["keyboard.shortcut.zone.0.modifiers"])
        XCTAssertEqual(saved["keyboard.future.setting"], .string("preserve"))
        XCTAssertEqual(saved["other.feature.flag"], .bool(true))
    }
}
