import XCTest

final class AppZoneHistoryPersistenceTests: XCTestCase {
    func testAppZoneHistoryRoundTripsOnlyStableKeysAndNormalizedZoneIDs() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let layout = PersistentStoreCoordinator.defaultLayout()
        let key = AppZoneHistoryKey(bundleID: "com.example.Editor", displayUUID: UUID(), spaceScope: .common, layoutID: layout.id)
        let record = AppZoneHistoryRecord(key: key, zoneIDs: [3, 1, 3], revision: 7)
        try await writeHistoryAndReleaseWriter(directory: directory, layout: layout, record: record)

        let urls = StoreURLs(directory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.appZoneHistory.path))
        let raw = try String(contentsOf: urls.appZoneHistory, encoding: .utf8)
        XCTAssertFalse(raw.contains("pid"))
        XCTAssertFalse(raw.contains("title"))
        XCTAssertFalse(raw.contains("AXUIElement"))
        let loaded = try await PersistentStoreCoordinator(directory: directory).load()
        XCTAssertTrue(loaded.appZoneHistoryAvailable)
        XCTAssertEqual(loaded.appZoneHistory[key]?.zoneIDs, [1, 3])
        XCTAssertEqual(loaded.appZoneHistory[key]?.revision, 7)
    }

    @MainActor
    func testInvalidHistoryKeepsRawRevisionSeedAndMaxRevisionDoesNotBlockBaseFlush() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let layout = PersistentStoreCoordinator.defaultLayout()
        let key = AppZoneHistoryKey(bundleID: "com.example.Editor", displayUUID: UUID(),
                                    spaceScope: .common, layoutID: layout.id)
        let urls = StoreURLs(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let invalid = AppZoneHistoryRecord(key: key, zoneIDs: [Int.max], revision: 100)
        let invalidBytes = try JSONEncoder().encode(VersionedStore(schemaVersion: 1,
                                                                    value: AppZoneHistoryStore(records: [invalid])))
        try invalidBytes.write(to: urls.appZoneHistory)

        let loaded = try await loadHistoryStateAndReleaseWriter(directory: directory)
        XCTAssertTrue(loaded.appZoneHistory.isEmpty)
        XCTAssertEqual(loaded.maxAppZoneHistoryRevision, 100)
        let layoutController = LayoutController(storeCoordinator: PersistentStoreCoordinator(directory: directory))
        await layoutController.loadPersistentState()
        layoutController.recordAppZoneHistory(key: key, expectedLayout: layout, zoneIDs: [0])
        let historyFlushed = await layoutController.flush()
        XCTAssertTrue(historyFlushed)
        let recoveredRevision = layoutController.appZoneHistory[key]?.revision
        XCTAssertEqual(recoveredRevision, 101,
                       "The controller allocates above a filtered invalid record's persisted revision.")

        let overflowDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: overflowDirectory) }
        let overflowURLs = StoreURLs(directory: overflowDirectory)
        try FileManager.default.createDirectory(at: overflowDirectory, withIntermediateDirectories: true)
        let exhausted = AppZoneHistoryRecord(key: key, zoneIDs: [Int.max], revision: .max)
        let exhaustedBytes = try JSONEncoder().encode(VersionedStore(schemaVersion: 1,
                                                                       value: AppZoneHistoryStore(records: [exhausted])))
        try exhaustedBytes.write(to: overflowURLs.appZoneHistory)
        let exhaustedController = LayoutController(
            storeCoordinator: PersistentStoreCoordinator(directory: overflowDirectory)
        )
        await exhaustedController.loadPersistentState()
        let exhaustedRevision = exhaustedController.nextAppZoneHistoryRevision
        let exhaustedHistory = exhaustedController.appZoneHistory
        XCTAssertEqual(exhaustedRevision, .max)
        XCTAssertTrue(exhaustedHistory.isEmpty)
        exhaustedController.recordAppZoneHistory(key: key, expectedLayout: layout, zoneIDs: [0])
        var settings = exhaustedController.appHistorySettings
        settings.monitorNewWindows = true
        exhaustedController.updateAppHistorySettings(settings)
        let exhaustedFlush = await exhaustedController.flush()
        XCTAssertTrue(exhaustedFlush, "Revision exhaustion pauses history writes without blocking base settings or prune flush.")
        let pendingHistory = exhaustedController.appZoneHistoryRetryRecords
        XCTAssertTrue(pendingHistory.isEmpty)
        let savedSettings = try JSONDecoder().decode(VersionedStore<SettingsStore>.self,
                                                     from: Data(contentsOf: overflowURLs.settings))
        XCTAssertFalse(savedSettings.value.values.isEmpty)
    }

    func testAppZoneHistoryWriteBeforeInitialLoadIsRejected() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = PersistentStoreCoordinator(directory: directory)
        let layout = PersistentStoreCoordinator.defaultLayout()
        try await coordinator.saveLayouts([layout])
        let key = AppZoneHistoryKey(bundleID: "com.example.Editor", displayUUID: UUID(), spaceScope: .common, layoutID: layout.id)
        do {
            try await coordinator.upsertAppZoneHistory(AppZoneHistoryRecord(key: key, zoneIDs: [0], revision: 1), expectedLayout: layout)
            XCTFail("History writes must wait for initial load and lock acquisition.")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: StoreURLs(directory: directory).appZoneHistory.path))
    }

    func testAppZoneHistoryRejectsStaleLayoutAndOutOfRangeZoneIDs() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = PersistentStoreCoordinator(directory: directory)
        let layout = PersistentStoreCoordinator.defaultLayout()
        _ = try await coordinator.load()
        try await coordinator.saveLayouts([layout])
        let key = AppZoneHistoryKey(bundleID: "com.example.Editor", displayUUID: UUID(), spaceScope: .common, layoutID: layout.id)

        do {
            try await coordinator.upsertAppZoneHistory(AppZoneHistoryRecord(key: key, zoneIDs: [4], revision: 1), expectedLayout: layout)
            XCTFail("out-of-range grid zone IDs must be rejected")
        } catch {}
        try await coordinator.saveLayouts([])
        do {
            try await coordinator.upsertAppZoneHistory(AppZoneHistoryRecord(key: key, zoneIDs: [0], revision: 2), expectedLayout: layout)
            XCTFail("deleted layout history must not be recreated")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: StoreURLs(directory: directory).appZoneHistory.path))
    }

    func testAppZoneHistoryPruneRemovesDeletedLayoutsAndLoadIsolatedFromCorruption() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = PersistentStoreCoordinator(directory: directory)
        let layout = PersistentStoreCoordinator.defaultLayout()
        _ = try await coordinator.load()
        try await coordinator.saveLayouts([layout])
        let key = AppZoneHistoryKey(bundleID: "com.example.Editor", displayUUID: UUID(), spaceScope: .common, layoutID: layout.id)
        try await coordinator.upsertAppZoneHistory(AppZoneHistoryRecord(key: key, zoneIDs: [0], revision: 1), expectedLayout: layout)
        try await coordinator.pruneAppZoneHistory(validLayouts: [:])
        let pruned = try await coordinator.load()
        XCTAssertTrue(pruned.appZoneHistory.isEmpty)

        let urls = StoreURLs(directory: directory)
        let damaged = Data("{broken".utf8)
        try damaged.write(to: urls.appZoneHistory)
        let state = try await coordinator.load()
        XCTAssertTrue(state.appZoneHistoryAvailable, "Verified backup should allow the isolated history store to recover empty and remain usable.")
        XCTAssertTrue(state.appZoneHistory.isEmpty)
        XCTAssertNotNil(state.layouts[PersistentStoreCoordinator.defaultLayoutID])
        let backup = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains("app-zone-history.json.") })
        XCTAssertEqual(try Data(contentsOf: backup), damaged)
    }

    func testAppZoneHistoryValidatesSparseMergedGridZoneIDsFromDefinition() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = PersistentStoreCoordinator(directory: directory)
        _ = try await coordinator.load()
        let sparseID = UUID()
        let sparse = PersistedLayout(id: sparseID, definition: .grid(GridLayout(
            id: LayoutID(rawValue: sparseID), rows: 2, columns: 2,
            rowPercentages: [5_000, 5_000], columnPercentages: [5_000, 5_000],
            cellChildMap: [[7, 8], [9, Int.max]]
        )), spacing: 0, template: .grid, zoneCount: 4)
        try await coordinator.saveLayouts([sparse])
        let key = AppZoneHistoryKey(bundleID: "com.example.Sparse", displayUUID: UUID(), spaceScope: .common, layoutID: sparseID)
        try await coordinator.upsertAppZoneHistory(AppZoneHistoryRecord(key: key, zoneIDs: [Int.max, 7], revision: 1), expectedLayout: sparse)
        let mergedID = UUID()
        let merged = PersistedLayout(id: mergedID, definition: .grid(GridLayout(
            id: LayoutID(rawValue: mergedID), rows: 2, columns: 2,
            rowPercentages: [5_000, 5_000], columnPercentages: [5_000, 5_000],
            cellChildMap: [[7, 7], [7, 7]]
        )), spacing: 0, template: .grid, zoneCount: 4)
        try await coordinator.saveLayouts([sparse, merged])
        let mergedKey = AppZoneHistoryKey(bundleID: "com.example.Merged", displayUUID: UUID(), spaceScope: .common, layoutID: mergedID)
        try await coordinator.upsertAppZoneHistory(AppZoneHistoryRecord(key: mergedKey, zoneIDs: [7], revision: 2), expectedLayout: merged)
        let state = try await coordinator.load()
        XCTAssertEqual(state.appZoneHistory[key]?.zoneIDs, [7, Int.max])
        XCTAssertEqual(state.appZoneHistory[mergedKey]?.zoneIDs, [7])
    }

    func testAppZoneHistoryRejectsSuccessFromSupersededLayoutDefinition() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = PersistentStoreCoordinator(directory: directory)
        _ = try await coordinator.load()
        let id = UUID()
        let original = PersistedLayout(id: id, definition: .grid(GridLayout(
            id: LayoutID(rawValue: id), rows: 1, columns: 2,
            rowPercentages: [10_000], columnPercentages: [5_000, 5_000], cellChildMap: [[3, 4]]
        )), spacing: 0, template: .grid, zoneCount: 2)
        let replacement = PersistedLayout(id: id, definition: .grid(GridLayout(
            id: LayoutID(rawValue: id), rows: 1, columns: 2,
            rowPercentages: [10_000], columnPercentages: [4_000, 6_000], cellChildMap: [[3, 4]]
        )), spacing: 0, template: .grid, zoneCount: 2)
        try await coordinator.saveLayouts([original])
        try await coordinator.saveLayouts([replacement])
        let key = AppZoneHistoryKey(bundleID: "com.example.Editor", displayUUID: UUID(), spaceScope: .common, layoutID: id)
        do {
            try await coordinator.upsertAppZoneHistory(AppZoneHistoryRecord(key: key, zoneIDs: [3], revision: 1), expectedLayout: original)
            XCTFail("a placement completed against a superseded layout must not be recorded")
        } catch {}
    }

    func testAppZoneHistoryUnavailableWriterDoesNotBlockBaseStoresOrQuitFlush() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = PersistentStoreCoordinator(directory: directory)
        let firstState = try await first.load()
        XCTAssertTrue(firstState.appZoneHistoryAvailable)

        let alias = directory.deletingLastPathComponent().appendingPathComponent("history-alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        defer { try? FileManager.default.removeItem(at: alias) }
        let second = PersistentStoreCoordinator(directory: alias)
        let secondState = try await second.load()
        XCTAssertFalse(secondState.appZoneHistoryAvailable)
        try await second.saveLayouts(Array(secondState.layouts.values))
        try await second.saveSettings(["base-setting": .bool(true)])
        try await second.flush()
        let savedState = try await second.load()
        XCTAssertEqual(savedState.settings["base-setting"], .bool(true))
    }

    func testAppZoneHistoryBackupFailureIsIsolatedFromBaseStoreFlush() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = StoreURLs(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{damaged".utf8).write(to: urls.appZoneHistory)
        let coordinator = PersistentStoreCoordinator(directory: directory, fileAccess: FailingAtomicFileAccess(failingWrite: { $0.lastPathComponent.contains(".backup") }))
        let state = try await coordinator.load()
        XCTAssertFalse(state.appZoneHistoryAvailable)
        try await coordinator.saveLayouts(Array(state.layouts.values))
        try await coordinator.saveSettings(["base-setting": .bool(true)])
        try await coordinator.flush()
    }

    func testAcceptedHistoryPruneFailureIsPendingUntilFlushRetry() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failure = OneShotWriteFailure()
        let coordinator = PersistentStoreCoordinator(directory: directory, fileAccess: FailingAtomicFileAccess(failingWrite: { failure.shouldFail($0) }))
        let layout = PersistentStoreCoordinator.defaultLayout()
        try await coordinator.saveLayouts([layout])
        let loaded = try await coordinator.load()
        XCTAssertTrue(loaded.appZoneHistoryAvailable)
        let key = AppZoneHistoryKey(bundleID: "com.example.Editor", displayUUID: UUID(), spaceScope: .common, layoutID: layout.id)
        try await coordinator.upsertAppZoneHistory(AppZoneHistoryRecord(key: key, zoneIDs: [0], revision: 1), expectedLayout: layout)

        failure.failNextWrites(to: "app-zone-history.json", count: 2)
        try await coordinator.saveLayouts([])
        XCTAssertTrue(failure.didFail("app-zone-history.json"), "An accepted layout deletion must attempt the history prune write.")
        do {
            try await coordinator.flush()
            XCTFail("an accepted prune I/O failure must remain visible to quit flush")
        } catch {}
        try await coordinator.flush()
        let after = try await coordinator.load()
        XCTAssertTrue(after.appZoneHistory.isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignHistoryPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeHistoryAndReleaseWriter(directory: URL, layout: PersistedLayout,
                                              record: AppZoneHistoryRecord) async throws {
        let coordinator = PersistentStoreCoordinator(directory: directory)
        _ = try await coordinator.load()
        try await coordinator.saveLayouts([layout])
        try await coordinator.upsertAppZoneHistory(record, expectedLayout: layout)
    }

    @MainActor
    private func loadHistoryStateAndReleaseWriter(directory: URL) async throws -> LoadedPersistentState {
        let coordinator = PersistentStoreCoordinator(directory: directory)
        return try await coordinator.load()
    }
}
