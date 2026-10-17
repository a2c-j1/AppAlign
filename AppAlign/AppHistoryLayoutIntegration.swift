import Foundation

@MainActor
extension LayoutController {
    /// A committed placement reports one stable-key delta. This work joins the same
    /// FIFO as layout/settings mutations and never treats history failure as a failed
    /// layout or quick-assignment save.
    func recordAppZoneHistory(key: AppZoneHistoryKey, expectedLayout: PersistedLayout, zoneIDs: [Int]) {
        guard acceptsChanges, persistenceReady, appZoneHistoryAvailable,
              let storeCoordinator,
              expectedLayout.id == key.layoutID,
              savedLayouts[key.layoutID] == expectedLayout else { return }
        guard nextAppZoneHistoryRevision < UInt64.max else {
            appZoneHistoryErrorMessage = "App window history revisions are exhausted; history recording is paused."
            return
        }
        nextAppZoneHistoryRevision += 1
        let record = AppZoneHistoryRecord(key: key, zoneIDs: zoneIDs, revision: nextAppZoneHistoryRevision)
        appZoneHistoryRetryRecords[key] = record
        appZoneHistoryRetryLayouts[key] = expectedLayout
        enqueueAppZoneHistoryDelta(record, expectedLayout: expectedLayout, using: storeCoordinator)
    }

    func reserveAppPlacement(token: RuntimeWindowToken, bundleID: String?, display: Display,
                             layout: PersistedLayout) -> AppHistoryCoordinator.Lease? {
        guard appZoneHistoryAvailable, let bundleID, let displayUUID = display.persistentID?.uuid,
              savedLayouts[layout.id] == layout else { return nil }
        return appHistoryCoordinator.reservePlacement(token: token, bundleID: bundleID,
                                                       displayUUID: displayUUID, expectedLayout: layout)
    }

    func acquireAppPlacement(_ lease: AppHistoryCoordinator.Lease?, using runtime: any WindowHistoryLeaseOperating) async -> AppHistoryCoordinator.Lease? {
        guard let lease else { return nil }
        guard await runtime.retainHistoryLease(lease.token, lease: lease.runtimeLeaseID) else {
            _ = appHistoryCoordinator.release(lease)
            return nil
        }
        guard appZoneHistoryAvailable, appHistoryCoordinator.isPending(lease) else {
            _ = appHistoryCoordinator.release(lease)
            await runtime.releaseHistoryLease(lease.token, lease: lease.runtimeLeaseID)
            return nil
        }
        return lease
    }

    func releaseAppPlacement(_ lease: AppHistoryCoordinator.Lease?) {
        guard let lease, appHistoryCoordinator.release(lease) else { return }
        appHistoryCoordinator.releaseRuntimeLease?(lease.token, lease.runtimeLeaseID)
    }

    func acceptSuccessfulAppPlacement(_ lease: AppHistoryCoordinator.Lease?, zoneIDs: [Int]) {
        guard let lease, let isOwner = appHistoryCoordinator.acceptSuccessfulPlacement(lease) else {
            if let lease { appHistoryCoordinator.releaseRuntimeLease?(lease.token, lease.runtimeLeaseID) }
            return
        }
        guard isOwner, appZoneHistoryAvailable else { return }
        recordAppZoneHistory(key: lease.key, expectedLayout: lease.expectedLayout, zoneIDs: zoneIDs)
    }

    func appWindowDestroyed(_ token: RuntimeWindowToken) {
        appHistoryCoordinator.windowDestroyed(token)
    }

    func appProcessTerminated(_ token: RuntimeWindowToken) {
        appHistoryCoordinator.processTerminated(token)
    }

    func appRestoreSucceeded(_ token: RuntimeWindowToken) {
        appHistoryCoordinator.restoreSucceeded(token)
    }

    func acceptSuccessfulAppRestore(_ lease: AppHistoryCoordinator.Lease?) {
        guard let lease, appHistoryCoordinator.acceptSuccessfulPlacement(lease) != nil else {
            if let lease { appHistoryCoordinator.releaseRuntimeLease?(lease.token, lease.runtimeLeaseID) }
            return
        }
    }

    func retryAppZoneHistorySaves() async -> Bool {
        guard let storeCoordinator else { return appZoneHistoryRetryRecords.isEmpty }
        guard !appZoneHistoryRetryRecords.isEmpty else { return true }
        let records = appZoneHistoryRetryRecords.values.sorted { $0.revision < $1.revision }
        let previous = saveChain
        let attempt = Task { @MainActor [weak self] () -> Bool in
            await previous?.value
            guard let self else { return false }
            for record in records {
                guard self.appZoneHistoryRetryRecords[record.key]?.revision == record.revision else { continue }
                guard let expectedLayout = self.appZoneHistoryRetryLayouts[record.key],
                      self.savedLayouts[record.key.layoutID] == expectedLayout else {
                    self.appZoneHistoryRetryRecords.removeValue(forKey: record.key)
                    self.appZoneHistoryRetryLayouts.removeValue(forKey: record.key)
                    continue
                }
                do {
                    try await storeCoordinator.upsertAppZoneHistory(record, expectedLayout: expectedLayout)
                    if self.appZoneHistoryRetryRecords[record.key]?.revision == record.revision {
                        self.appZoneHistoryRetryRecords.removeValue(forKey: record.key)
                        self.appZoneHistoryRetryLayouts.removeValue(forKey: record.key)
                        self.appZoneHistory[record.key] = record
                    }
                } catch {
                    self.appZoneHistoryErrorMessage = error.localizedDescription
                    return false
                }
            }
            if self.appZoneHistoryRetryRecords.isEmpty {
                self.appZoneHistoryErrorMessage = nil
            }
            return true
        }
        saveChain = Task { @MainActor in _ = await attempt.value }
        return await attempt.value
    }

    private func enqueueAppZoneHistoryDelta(_ record: AppZoneHistoryRecord, expectedLayout: PersistedLayout,
                                            using coordinator: PersistentStoreCoordinator) {
        let previous = saveChain
        saveChain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.appZoneHistoryRetryRecords[record.key]?.revision == record.revision else { return }
            do {
                try await coordinator.upsertAppZoneHistory(record, expectedLayout: expectedLayout)
                if self.appZoneHistoryRetryRecords[record.key]?.revision == record.revision {
                    self.appZoneHistoryRetryRecords.removeValue(forKey: record.key)
                    self.appZoneHistoryRetryLayouts.removeValue(forKey: record.key)
                    self.appZoneHistory[record.key] = record
                }
                if self.appZoneHistoryRetryRecords.isEmpty {
                    self.appZoneHistoryErrorMessage = nil
                }
            } catch {
                if self.savedLayouts[record.key.layoutID] != expectedLayout {
                    self.appZoneHistoryRetryRecords.removeValue(forKey: record.key)
                    self.appZoneHistoryRetryLayouts.removeValue(forKey: record.key)
                } else {
                    self.appZoneHistoryErrorMessage = error.localizedDescription
                }
            }
        }
    }
}
