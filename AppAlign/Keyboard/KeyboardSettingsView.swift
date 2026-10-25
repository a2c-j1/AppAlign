import SwiftUI

struct KeyboardSettingsView: View {
    @EnvironmentObject private var layoutController: LayoutController
    @EnvironmentObject private var placementController: PlacementController
    @EnvironmentObject private var keyboardSnapController: KeyboardSnapController
    @EnvironmentObject private var globalHotkeys: GlobalHotkeys
    @EnvironmentObject private var layoutHotkeys: LayoutHotkeys
    @State private var zoneToAdd: ZoneID?

    private var settings: KeyboardSettings { layoutController.keyboardSettings }
    private var actions: [KeyboardSnapAction] {
        settings.shortcuts.keys.sorted { actionName($0) < actionName($1) }
    }

    var body: some View {
        GroupBox("Keyboard placement") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable global shortcuts", isOn: Binding(
                    get: { settings.isEnabled },
                    set: { value in var next = settings; next.isEnabled = value; save(next) }
                ))
                .disabled(!layoutController.canEdit)
                Picker("Navigation mode", selection: Binding(
                    get: { settings.mode },
                    set: { value in var next = settings; next.mode = value; save(next) }
                )) {
                    Text("Zone order").tag(NavigationMode.zoneOrder)
                    Text("Window position").tag(NavigationMode.position)
                }
                .disabled(!layoutController.canEdit)
                Toggle("Cycle at the layout edge", isOn: Binding(
                    get: { settings.cyclesAtEdges },
                    set: { value in var next = settings; next.cyclesAtEdges = value; save(next) }
                ))
                .disabled(!layoutController.canEdit)

                Text("Zone-order mode uses Left and Right for adjacent existing zones. Up and Down are inactive. Window-position mode uses all four directions from the window's current center.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Divider()
                ForEach(actions, id: \.self) { action in
                    shortcutRow(action)
                }
                HStack {
                    Picker("Add shortcut for zone", selection: $zoneToAdd) {
                        Text("Choose a zone").tag(Optional<ZoneID>.none)
                        ForEach(layoutController.keyboardZoneChoices, id: \.self) { id in
                            Text(L10n.string(zoneLabel(id))).tag(Optional(id))
                        }
                    }
                    .frame(maxWidth: 260)
                    Button("Add zone shortcut") { addZoneShortcut() }
                        .disabled(zoneToAdd == nil || !layoutController.canEdit)
                }
                Text("Zone shortcuts use IDs from applied layouts on connected displays, so they stay stable when display labels collide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(settings.shortcutIssues, id: \.self) { issue in
                    Text(L10n.string(issue)).font(.caption).foregroundStyle(.red)
                }

                Divider()
                HStack {
                    Label(L10n.string(placementController.accessibilityGranted ? "Accessibility access granted" : "Accessibility access required"), systemImage: placementController.accessibilityGranted ? "checkmark.shield" : "hand.raised")
                    if !placementController.accessibilityGranted {
                        Button("Request access") { placementController.requestAccessibilityAccess() }
                    }
                }
                Text(L10n.string(globalHotkeys.statusMessage))
                    .font(.callout)
                    .foregroundStyle(globalHotkeys.statusMessage.contains("Could not") || globalHotkeys.statusMessage.contains("not") ? .red : .secondary)
                Text(L10n.string(keyboardSnapController.statusMessage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let error = layoutController.keyboardSettingsErrorMessage {
                    Text(L10n.string(error)).font(.caption).foregroundStyle(.red)
                }
                Text("Carbon consumes a registered shortcut. If Accessibility fails after macOS delivers a registered key, AppAlign cannot guarantee that the original app receives it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()
                GroupBox("Quick layout switching") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable layout shortcuts", isOn: Binding(
                            get: { layoutController.layoutHotkeySettings.isEnabled },
                            set: { enabled in
                                var updated = layoutController.layoutHotkeySettings
                                updated.isEnabled = enabled
                                saveLayoutHotkeys(updated)
                            }
                        ))
                        .disabled(!layoutController.canEdit)
                        ForEach(layoutHotkeyLayouts, id: \.id) { layout in
                            layoutShortcutRow(layout)
                        }
                        Text(L10n.string(layoutHotkeys.statusMessage)).font(.caption).foregroundStyle(.secondary)
                        Text("Each shortcut applies its saved layout to the display under the pointer. Drag detection uses Accessibility permission and input is never suppressed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func shortcutRow(_ action: KeyboardSnapAction) -> some View {
        let shortcut = settings.shortcuts[action] ?? KeyboardShortcut(keyCode: 0, modifiers: 0)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.string(actionName(action))).frame(width: 120, alignment: .leading)
                Picker("Key", selection: Binding(
                    get: { shortcut.keyCode },
                    set: { value in updateShortcut(action) { $0.keyCode = value } }
                )) {
                    ForEach(Self.keyChoices, id: \.code) { key in
                        Text(key.label).tag(key.code)
                    }
                }
                .frame(width: 125)
                modifierToggle("⇧", bit: KeyboardShortcut.shift, action: action, shortcut: shortcut)
                modifierToggle("⌃", bit: KeyboardShortcut.control, action: action, shortcut: shortcut)
                modifierToggle("⌥", bit: KeyboardShortcut.option, action: action, shortcut: shortcut)
                modifierToggle("⌘", bit: KeyboardShortcut.command, action: action, shortcut: shortcut)
                Button("Disable shortcut") { updateShortcut(action) { $0.modifiers = 0 } }
                    .buttonStyle(.borderless)
            }
            .disabled(!layoutController.canEdit)
            if case .zone(let id) = action {
                Text(L10n.string("Display number: \(id.displayNumber)"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func modifierToggle(_ title: String, bit: UInt32, action: KeyboardSnapAction, shortcut: KeyboardShortcut) -> some View {
        Toggle(title, isOn: Binding(
            get: { shortcut.modifiers & bit != 0 },
            set: { enabled in updateShortcut(action) { value in
                if enabled { value.modifiers |= bit } else { value.modifiers &= ~bit }
            } }
        ))
        .toggleStyle(.button)
        .labelsHidden()
    }

    private func save(_ updated: KeyboardSettings) {
        layoutController.updateKeyboardSettings(updated)
        globalHotkeys.settingsDidChange()
    }

    private func updateShortcut(_ action: KeyboardSnapAction, mutation: (inout KeyboardShortcut) -> Void) {
        var updated = settings
        var shortcut = updated.shortcuts[action] ?? KeyboardShortcut(keyCode: 0, modifiers: 0)
        mutation(&shortcut)
        updated.shortcuts[action] = shortcut
        save(updated)
    }

    private func actionName(_ action: KeyboardSnapAction) -> String {
        switch action {
        case .zone(let id): zoneLabel(id)
        case .next: "Next zone"
        case .previous: "Previous zone"
        case .direction(let direction): "Move \(direction.rawValue.capitalized)"
        case .extend(let direction): "Extend \(direction.rawValue.capitalized)"
        case .restore: "Restore original"
        }
    }

    private var layoutHotkeyLayouts: [PersistedLayout] {
        var values = Array(layoutController.savedLayouts.values)
        if !values.contains(where: { $0.id == PersistentStoreCoordinator.defaultLayoutID }) {
            values.append(PersistentStoreCoordinator.defaultLayout())
        }
        return values.sorted {
            let left = ($0.name ?? "Default").localizedStandardCompare($1.name ?? "Default")
            return left == .orderedSame ? $0.id.uuidString < $1.id.uuidString : left == .orderedAscending
        }
    }

    @ViewBuilder
    private func layoutShortcutRow(_ layout: PersistedLayout) -> some View {
        let current = layoutController.layoutHotkeySettings.bindings[layout.id]
            ?? KeyboardShortcut(keyCode: 37, modifiers: KeyboardShortcut.defaultModifiers | KeyboardShortcut.shift)
        HStack {
            Text(layout.name ?? L10n.string(layout.id == PersistentStoreCoordinator.defaultLayoutID ? "Default" : "Layout"))
                .frame(width: 130, alignment: .leading)
            Picker("Key", selection: Binding(
                get: { current.keyCode },
                set: { key in updateLayoutBinding(layout.id) { $0.keyCode = key } }
            )) {
                ForEach(Self.keyChoices, id: \.code) { key in Text(key.label).tag(key.code) }
            }
            .frame(width: 120)
            modifierToggle(title: "⇧", bit: KeyboardShortcut.shift, layoutID: layout.id, shortcut: current)
            modifierToggle(title: "⌃", bit: KeyboardShortcut.control, layoutID: layout.id, shortcut: current)
            modifierToggle(title: "⌥", bit: KeyboardShortcut.option, layoutID: layout.id, shortcut: current)
            modifierToggle(title: "⌘", bit: KeyboardShortcut.command, layoutID: layout.id, shortcut: current)
        }
        .disabled(!layoutController.canEdit)
    }

    private func modifierToggle(title: String, bit: UInt32, layoutID: UUID, shortcut: KeyboardShortcut) -> some View {
        Toggle(title, isOn: Binding(
            get: { shortcut.modifiers & bit != 0 },
            set: { enabled in updateLayoutBinding(layoutID) { value in
                if enabled { value.modifiers |= bit } else { value.modifiers &= ~bit }
            } }
        ))
        .toggleStyle(.button)
        .labelsHidden()
    }

    private func updateLayoutBinding(_ id: UUID, mutation: (inout KeyboardShortcut) -> Void) {
        var updated = layoutController.layoutHotkeySettings
        var shortcut = updated.bindings[id]
            ?? KeyboardShortcut(keyCode: 37, modifiers: KeyboardShortcut.defaultModifiers | KeyboardShortcut.shift)
        mutation(&shortcut)
        updated.bindings[id] = shortcut
        saveLayoutHotkeys(updated)
    }

    private func saveLayoutHotkeys(_ updated: LayoutHotkeySettings) {
        layoutController.updateLayoutHotkeySettings(updated)
        layoutHotkeys.settingsDidChange()
    }

    private func zoneLabel(_ id: ZoneID) -> String {
        let collides = id.rawValue == Int.max || id.rawValue == Int.max - 1
        return collides ? "Zone \(id.displayNumber) (ID \(id.rawValue))" : "Zone \(id.displayNumber)"
    }

    private func addZoneShortcut() {
        guard let id = zoneToAdd else { return }
        var updated = settings
        let action = KeyboardSnapAction.zone(id)
        if updated.shortcuts[action] == nil {
            let used = Set(updated.shortcuts.values.map(\.keyCode))
            let keyCode = Self.keyChoices.map(\.code).first(where: { !used.contains($0) }) ?? 0
            updated.shortcuts[action] = KeyboardShortcut(keyCode: keyCode, modifiers: KeyboardShortcut.defaultModifiers)
            save(updated)
        }
        zoneToAdd = nil
    }

    private struct KeyChoice {
        let code: UInt16
        let label: String
    }

    private static let keyChoices: [KeyChoice] = [
        .init(code: 18, label: "1"), .init(code: 19, label: "2"), .init(code: 20, label: "3"),
        .init(code: 21, label: "4"), .init(code: 23, label: "5"), .init(code: 22, label: "6"),
        .init(code: 26, label: "7"), .init(code: 28, label: "8"), .init(code: 25, label: "9"),
        .init(code: 123, label: "←"), .init(code: 124, label: "→"), .init(code: 126, label: "↑"), .init(code: 125, label: "↓"),
        .init(code: 0, label: "A"), .init(code: 11, label: "B"), .init(code: 8, label: "C"), .init(code: 2, label: "D"),
        .init(code: 14, label: "E"), .init(code: 3, label: "F"), .init(code: 5, label: "G"), .init(code: 4, label: "H"),
        .init(code: 34, label: "I"), .init(code: 38, label: "J"), .init(code: 40, label: "K"), .init(code: 37, label: "L"),
        .init(code: 46, label: "M"), .init(code: 45, label: "N"), .init(code: 31, label: "O"), .init(code: 35, label: "P"),
        .init(code: 12, label: "Q"), .init(code: 15, label: "R"), .init(code: 1, label: "S"), .init(code: 17, label: "T"),
        .init(code: 32, label: "U"), .init(code: 9, label: "V"), .init(code: 13, label: "W"), .init(code: 7, label: "X"),
        .init(code: 16, label: "Y"), .init(code: 6, label: "Z"), .init(code: 33, label: "["), .init(code: 30, label: "]")
    ]
}
