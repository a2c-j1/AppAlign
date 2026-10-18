import Carbon.HIToolbox
import XCTest

final class KeyboardSettingsTests: XCTestCase {
    func testKeyboardExtensionDefaultsUseShiftIndependentlyAndPersist() {
        let settings = KeyboardSettings()
        for direction in NavigationDirection.allCases {
            XCTAssertEqual(settings.shortcuts[.extend(direction)]?.modifiers,
                           KeyboardShortcut.defaultModifiers | KeyboardShortcut.shift)
            XCTAssertEqual(settings.shortcuts[.direction(direction)]?.modifiers, KeyboardShortcut.defaultModifiers)
        }
        let values = settings.applying(to: ["unrecognized.setting": .string("keep")])
        let decoded = KeyboardSettings.decode(from: values)
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(values["unrecognized.setting"], .string("keep"))
    }

    func testLayoutHotkeySettingsRoundTripAndPreserveUnknownKeys() {
        let id = UUID()
        let shortcut = KeyboardShortcut(keyCode: 37, modifiers: KeyboardShortcut.defaultModifiers | KeyboardShortcut.shift)
        var settings = LayoutHotkeySettings()
        settings.isEnabled = true
        settings.bindings[id] = shortcut
        let values = settings.applying(to: ["future.layout.setting": .bool(true)])
        XCTAssertEqual(LayoutHotkeySettings.decode(from: values), settings)
        XCTAssertEqual(values["future.layout.setting"], .bool(true))
        XCTAssertEqual(LayoutHotkeySettings.decode(from: ["layout.hotkey.enabled": .bool(true),
                                                          "layout.hotkey.invalid.key": .integer(1)]).bindings, [:])
    }

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

    @MainActor
    func testAppHistorySettingsPersistAcrossCategoryUpdatesAndKeepUnknownValues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignHistorySettings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStoreCoordinator(directory: directory)
        try await store.saveLayouts([PersistentStoreCoordinator.defaultLayout()])
        try await store.saveSettings(["appHistory.future.option": .string("keep")])
        let layout = LayoutController(storeCoordinator: store)
        await layout.loadPersistentState()
        XCTAssertFalse(layout.appHistorySettings.monitorNewWindows)
        XCTAssertFalse(layout.appHistorySettings.restoreNewWindows)

        var history = layout.appHistorySettings
        history.monitorNewWindows = true
        history.restoreNewWindows = true
        layout.updateAppHistorySettings(history)
        var keyboard = layout.keyboardSettings
        keyboard.isEnabled = true
        layout.updateKeyboardSettings(keyboard)
        let flushed = await layout.flush()
        XCTAssertTrue(flushed)

        let reloaded = LayoutController(storeCoordinator: PersistentStoreCoordinator(directory: directory))
        await reloaded.loadPersistentState()
        XCTAssertTrue(reloaded.appHistorySettings.monitorNewWindows)
        XCTAssertTrue(reloaded.appHistorySettings.restoreNewWindows)
        XCTAssertTrue(reloaded.keyboardSettings.isEnabled)
        XCTAssertEqual(reloaded.settings["appHistory.future.option"], .string("keep"))
    }
}
