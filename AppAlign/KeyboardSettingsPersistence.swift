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
        let revision = keyboardSettingsRevision
        let snapshot = settings
        keyboardSettingsRetrySnapshot = snapshot
        guard let storeCoordinator else {
            keyboardSettingsErrorMessage = "Keyboard settings could not be saved because storage is unavailable."
            return
        }
        let previous = saveChain
        saveChain = Task { @MainActor [weak self] in
            await previous?.value
            do {
                try await storeCoordinator.saveSettings(snapshot)
                guard let self, revision == self.keyboardSettingsRevision else { return }
                self.keyboardSettingsRetrySnapshot = nil
                self.keyboardSettingsErrorMessage = nil
            } catch {
                guard let self, revision == self.keyboardSettingsRevision else { return }
                self.keyboardSettingsRetrySnapshot = snapshot
                self.keyboardSettingsErrorMessage = error.localizedDescription
            }
        }
    }

    func retryKeyboardSettingsSave() async -> Bool {
        guard let snapshot = keyboardSettingsRetrySnapshot, let storeCoordinator else { return true }
        let revision = keyboardSettingsRevision
        let previous = saveChain
        let attempt = Task { @MainActor [weak self] () -> Bool in
            await previous?.value
            guard let self, revision == self.keyboardSettingsRevision,
                  self.keyboardSettingsRetrySnapshot == snapshot else { return false }
            do {
                try await storeCoordinator.saveSettings(snapshot)
                guard revision == self.keyboardSettingsRevision else { return false }
                self.keyboardSettingsRetrySnapshot = nil
                self.keyboardSettingsErrorMessage = nil
                return true
            } catch {
                guard revision == self.keyboardSettingsRevision else { return false }
                self.keyboardSettingsRetrySnapshot = snapshot
                self.keyboardSettingsErrorMessage = error.localizedDescription
                return false
            }
        }
        saveChain = Task { @MainActor in _ = await attempt.value }
        return await attempt.value
    }

    func adoptSettings(_ loaded: [String: PersistedSetting]) {
        if let keyboardSettingsRetrySnapshot {
            var merged = loaded
            let managedKeys = KeyboardSettings.managedKeys(in: loaded).union(KeyboardSettings.managedKeys(in: keyboardSettingsRetrySnapshot))
            for key in managedKeys { merged.removeValue(forKey: key) }
            merged.merge(keyboardSettingsRetrySnapshot.filter { managedKeys.contains($0.key) }) { _, pending in pending }
            settings = merged
            self.keyboardSettingsRetrySnapshot = merged
            keyboardSettings = KeyboardSettings.decode(from: merged)
        } else {
            settings = loaded
            keyboardSettings = KeyboardSettings.decode(from: loaded)
        }
    }
}
