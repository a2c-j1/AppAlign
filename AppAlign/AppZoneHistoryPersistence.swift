import Darwin
import Foundation

extension PersistentStoreCoordinator {
    /// Applies one event to the latest successfully saved catalog. The actor performs
    /// the read/validate/write sequence synchronously, so a stale UI snapshot cannot
    /// resurrect a deleted layout or save draft zone IDs.
    func upsertAppZoneHistory(_ proposed: AppZoneHistoryRecord, expectedLayout: PersistedLayout) throws {
        guard appZoneHistoryLoadAttempted, appZoneHistoryAvailable else {
            throw PersistenceError.storeUnavailable("app-zone-history has not been loaded")
        }
        try ensureAppZoneHistoryWriter()
        guard appZoneHistoryAvailable else { throw PersistenceError.storeUnavailable("app-zone-history") }
        guard !proposed.key.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !proposed.zoneIDs.isEmpty,
              proposed.zoneIDs == AppZoneHistoryRecord.normalized(proposed.zoneIDs) else {
            throw PersistenceError.invalidData("app zone history record")
        }
        let catalog = try loadStore(LayoutStore.self, at: urls.layouts, name: "layouts",
                                    default: LayoutStore(layouts: [Self.defaultLayout()]), validate: Self.validateLayouts)
        let layouts = Dictionary(uniqueKeysWithValues: catalog.value.layouts.map { ($0.id, $0) })
        guard layouts[proposed.key.layoutID] == expectedLayout,
              Self.isValid(proposed, layouts: layouts) else {
            throw PersistenceError.invalidData("app zone history references an unavailable layout or zone")
        }
        let loaded = try loadStore(AppZoneHistoryStore.self, at: urls.appZoneHistory, name: "app-zone-history",
                                   default: AppZoneHistoryStore(records: []), validate: Self.validateAppZoneHistory)
        var records = Dictionary(uniqueKeysWithValues: loaded.value.records.map { ($0.key, $0) })
        if let previous = records[proposed.key], previous.revision >= proposed.revision {
            throw PersistenceError.invalidData("stale app zone history revision")
        }
        records[proposed.key] = proposed
        let ordered = records.values.sorted(by: Self.historyOrder)
        try backupLegacyStoreIfNeeded(name: "app-zone-history", url: urls.appZoneHistory)
        try save(AppZoneHistoryStore(records: ordered), to: urls.appZoneHistory)
        markLegacyStoreMigrated("app-zone-history")
    }

    func pruneAppZoneHistory(validLayouts: [UUID: PersistedLayout]) throws {
        guard appZoneHistoryLoadAttempted, appZoneHistoryAvailable else {
            throw PersistenceError.storeUnavailable("app-zone-history has not been loaded")
        }
        try ensureAppZoneHistoryWriter()
        guard appZoneHistoryAvailable else { return }
        let loaded = try loadStore(AppZoneHistoryStore.self, at: urls.appZoneHistory, name: "app-zone-history",
                                   default: AppZoneHistoryStore(records: []), validate: Self.validateAppZoneHistory)
        let remaining = loaded.value.records.filter { Self.isValid($0, layouts: validLayouts) }
        if remaining.count != loaded.value.records.count {
            try backupLegacyStoreIfNeeded(name: "app-zone-history", url: urls.appZoneHistory)
            try save(AppZoneHistoryStore(records: remaining.sorted(by: Self.historyOrder)), to: urls.appZoneHistory)
            markLegacyStoreMigrated("app-zone-history")
        }
        appZoneHistoryNeedsPrune = false
    }

    func ensureAppZoneHistoryWriter() throws {
        try ensureWritable("app-zone-history")
        guard !appZoneHistoryWriterUnavailable else { throw PersistenceError.storeUnavailable("app-zone-history writer") }
        if appZoneHistoryWriterFD != nil { return }
        let lockURL = urls.appZoneHistory.deletingLastPathComponent().appendingPathComponent("app-zone-history.lock")
        var claimedLockPath: String?
        do {
            try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let lockPath = lockURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard AppZoneHistoryWriterProcessLock.claim(lockPath) else {
                appZoneHistoryWriterUnavailable = true
                throw PersistenceError.storeUnavailable("app-zone-history writer")
            }
            claimedLockPath = lockPath
            let descriptor = lockPath.withCString { Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR) }
            guard descriptor >= 0 else { throw PersistenceError.storeUnavailable("app-zone-history writer") }
            guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
                _ = Darwin.close(descriptor)
                AppZoneHistoryWriterProcessLock.release(lockPath)
                throw PersistenceError.storeUnavailable("app-zone-history writer")
            }
            appZoneHistoryWriterFD = descriptor
            appZoneHistoryWriterPath = lockPath
            appZoneHistoryAvailable = true
        } catch {
            if let claimedLockPath { AppZoneHistoryWriterProcessLock.release(claimedLockPath) }
            appZoneHistoryWriterUnavailable = true
            throw PersistenceError.storeUnavailable("app-zone-history writer")
        }
    }

    static func validateAppZoneHistory(_ store: AppZoneHistoryStore) throws {
        guard Set(store.records.map(\.key)).count == store.records.count,
              store.records.allSatisfy({
                  !$0.key.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      !$0.zoneIDs.isEmpty && $0.zoneIDs == AppZoneHistoryRecord.normalized($0.zoneIDs)
              }) else { throw PersistenceError.invalidData("app zone history") }
    }

    static func isValid(_ record: AppZoneHistoryRecord, layouts: [UUID: PersistedLayout]) -> Bool {
        guard let layout = layouts[record.key.layoutID],
              !record.key.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !record.zoneIDs.isEmpty,
              record.zoneIDs == AppZoneHistoryRecord.normalized(record.zoneIDs) else { return false }
        let allowed: Set<Int>
        switch layout.kind {
        case .grid: allowed = Set(layout.cellChildMap?.flatMap { $0 } ?? [])
        case .canvas, .focus: allowed = Set(layout.zones?.map(\.id) ?? [])
        }
        return record.zoneIDs.allSatisfy(allowed.contains)
    }

    static func historyOrder(_ lhs: AppZoneHistoryRecord, _ rhs: AppZoneHistoryRecord) -> Bool {
        if lhs.key.bundleID != rhs.key.bundleID { return lhs.key.bundleID < rhs.key.bundleID }
        if lhs.key.displayUUID != rhs.key.displayUUID { return lhs.key.displayUUID.uuidString < rhs.key.displayUUID.uuidString }
        return lhs.key.layoutID.uuidString < rhs.key.layoutID.uuidString
    }
}
