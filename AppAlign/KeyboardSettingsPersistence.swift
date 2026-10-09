import Foundation

@MainActor
extension LayoutController {
    static func applicationStoreDirectory() -> URL? {
        #if DEBUG
            if let path = ProcessInfo.processInfo.environment["APPALIGN_STORAGE_DIRECTORY"], !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        #endif
        return try? PersistentStoreCoordinator.applicationSupportDirectory()
    }

    func updateKeyboardSettings(_ updated: KeyboardSettings) {
        guard acceptsChanges, persistenceReady else { return }
        keyboardSettings = updated
        settings = updated.applying(to: settings)
        keyboardSettingsRevision &+= 1
        keyboardSettingsRetrySnapshot = settings
        enqueueSettingsSave(category: .keyboard, revision: keyboardSettingsRevision)
    }

    func updateDragSettings(_ updated: DragSettings) {
        guard acceptsChanges, persistenceReady else { return }
        invalidateDragCommit?()
        dragSettings = updated
        settings = updated.applying(to: settings)
        dragSettingsRevision &+= 1
        dragSettingsRetrySnapshot = settings
        enqueueSettingsSave(category: .drag, revision: dragSettingsRevision)
    }

    func retryKeyboardSettingsSave() async -> Bool {
        await retrySettingsSave(category: .keyboard)
    }

    func retryDragSettingsSave() async -> Bool {
        await retrySettingsSave(category: .drag)
    }

    func adoptSettings(_ loaded: [String: PersistedSetting]) {
        var merged = loaded
        if let snapshot = keyboardSettingsRetrySnapshot {
            let keys = KeyboardSettings.managedKeys(in: merged).union(KeyboardSettings.managedKeys(in: snapshot))
            for key in keys { merged.removeValue(forKey: key) }
            merged.merge(snapshot.filter { keys.contains($0.key) }) { _, pending in pending }
        }
        if let snapshot = dragSettingsRetrySnapshot {
            for key in DragSettings.managedKeys { merged.removeValue(forKey: key) }
            merged.merge(snapshot.filter { DragSettings.managedKeys.contains($0.key) }) { _, pending in pending }
        }
        settings = merged
        keyboardSettings = KeyboardSettings.decode(from: merged)
        dragSettings = DragSettings.decode(from: merged)
    }

    private enum SettingsCategory: Equatable { case keyboard, drag }

    private func enqueueSettingsSave(category: SettingsCategory, revision: UInt64) {
        guard let storeCoordinator else {
            keyboardSettingsErrorMessage = "Settings could not be saved because storage is unavailable."
            return
        }
        let previous = saveChain
        saveChain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.isCurrentSettingsRevision(category, revision) else { return }
            do {
                try await storeCoordinator.saveSettings(self.settingsForPersistence())
                guard self.isCurrentSettingsRevision(category, revision) else { return }
                self.clearSettingsRetry(category)
                self.keyboardSettingsErrorMessage = nil
            } catch {
                guard self.isCurrentSettingsRevision(category, revision) else { return }
                self.markSettingsRetry(category)
                self.keyboardSettingsErrorMessage = error.localizedDescription
            }
        }
    }

    private func retrySettingsSave(category: SettingsCategory) async -> Bool {
        guard let storeCoordinator, hasSettingsRetry(category) else { return true }
        let revision = settingsRevision(category)
        let previous = saveChain
        let attempt = Task { @MainActor [weak self] () -> Bool in
            await previous?.value
            guard let self, self.isCurrentSettingsRevision(category, revision), self.hasSettingsRetry(category) else { return false }
            do {
                try await storeCoordinator.saveSettings(self.settingsForPersistence())
                guard self.isCurrentSettingsRevision(category, revision) else { return false }
                self.clearSettingsRetry(category)
                self.keyboardSettingsErrorMessage = nil
                return true
            } catch {
                guard self.isCurrentSettingsRevision(category, revision) else { return false }
                self.markSettingsRetry(category)
                self.keyboardSettingsErrorMessage = error.localizedDescription
                return false
            }
        }
        saveChain = Task { @MainActor in _ = await attempt.value }
        return await attempt.value
    }

    private func settingsForPersistence() -> [String: PersistedSetting] {
        var result = settings
        mergePending(keyboardSettingsRetrySnapshot, keys: KeyboardSettings.managedKeys(in: settings), into: &result)
        mergePending(dragSettingsRetrySnapshot, keys: DragSettings.managedKeys, into: &result)
        return result
    }

    private func mergePending(_ snapshot: [String: PersistedSetting]?, keys: Set<String>, into result: inout [String: PersistedSetting]) {
        guard let snapshot else { return }
        for key in keys { result.removeValue(forKey: key) }
        result.merge(snapshot.filter { keys.contains($0.key) }) { _, pending in pending }
    }

    private func settingsRevision(_ category: SettingsCategory) -> UInt64 {
        category == .keyboard ? keyboardSettingsRevision : dragSettingsRevision
    }

    private func isCurrentSettingsRevision(_ category: SettingsCategory, _ revision: UInt64) -> Bool {
        settingsRevision(category) == revision
    }

    private func hasSettingsRetry(_ category: SettingsCategory) -> Bool {
        category == .keyboard ? keyboardSettingsRetrySnapshot != nil : dragSettingsRetrySnapshot != nil
    }

    private func markSettingsRetry(_ category: SettingsCategory) {
        if category == .keyboard { keyboardSettingsRetrySnapshot = settings } else { dragSettingsRetrySnapshot = settings }
    }

    private func clearSettingsRetry(_ category: SettingsCategory) {
        if category == .keyboard { keyboardSettingsRetrySnapshot = nil } else { dragSettingsRetrySnapshot = nil }
    }
}
