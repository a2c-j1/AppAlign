import CoreGraphics
import Foundation
import XCTest

final class PersistenceTests: XCTestCase {
    func testThreeVersionedStoresRoundTripGridCanvasFocusAndSettings() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = PersistentStoreCoordinator(directory: directory)
        let gridID = UUID()
        let canvasID = UUID()
        let focusID = UUID()
        let grid = GridLayout(
            id: LayoutID(rawValue: gridID), rows: 1, columns: 2,
            rowPercentages: [10_000], columnPercentages: [4_000, 6_000], cellChildMap: [[4, 9]]
        )
        let canvas = CanvasLayout(
            id: LayoutID(rawValue: canvasID), referenceSize: CGSize(width: 800, height: 600),
            zones: [CanvasZone(id: ZoneID(rawValue: 12), frame: CGRect(x: 10, y: 20, width: 300, height: 200))]
        )
        let focus = CanvasLayout(
            id: LayoutID(rawValue: focusID), referenceSize: CGSize(width: 800, height: 600),
            zones: [CanvasZone(id: ZoneID(rawValue: 20), frame: CGRect(x: 10, y: 20, width: 300, height: 200))]
        )
        let layouts = [
            PersistedLayout(id: gridID, definition: .grid(grid), spacing: 10, template: .grid, zoneCount: 2),
            PersistedLayout(id: canvasID, definition: .canvas(canvas), spacing: 0, template: .columns, zoneCount: 1),
            PersistedLayout(id: focusID, definition: .focus(focus), spacing: 8, template: .focus, zoneCount: 1)
        ]
        let displayUUID = UUID()
        try await coordinator.saveLayoutAndAssignments(
            layouts,
            [PersistedAssignment(displayUUID: displayUUID, spaceScope: .common, layoutID: gridID)]
        )
        try await coordinator.saveSettings(["enabled": .bool(true), "count": .integer(4), "label": .string("desk")])

        let urls = StoreURLs(directory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.layouts.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.assignments.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.settings.path))
        let layoutObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: urls.layouts)) as? [String: Any])
        let assignmentObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: urls.assignments)) as? [String: Any])
        let settingsObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: urls.settings)) as? [String: Any])
        XCTAssertEqual(layoutObject["schemaVersion"] as? Int, 1)
        XCTAssertEqual(assignmentObject["schemaVersion"] as? Int, 1)
        XCTAssertEqual(settingsObject["schemaVersion"] as? Int, 1)

        let loaded = try await PersistentStoreCoordinator(directory: directory).load()
        let restoredGrid = try loaded.layouts[gridID]?.definition()
        let restoredCanvas = try loaded.layouts[canvasID]?.definition()
        let restoredFocus = try loaded.layouts[focusID]?.definition()
        XCTAssertEqual(restoredGrid, .grid(grid))
        XCTAssertEqual(restoredCanvas, .canvas(canvas))
        XCTAssertEqual(restoredFocus, .focus(focus))
        XCTAssertEqual(loaded.layouts[gridID]?.spacing, 10)
        XCTAssertEqual(loaded.assignments[displayUUID]?.spaceScope, .common)
        XCTAssertEqual(loaded.settings["enabled"], .bool(true))
        XCTAssertEqual(loaded.settings["count"], .integer(4))
        XCTAssertEqual(loaded.settings["label"], .string("desk"))
    }

    func testCoordinatorReplacementFailurePreservesPreviousSettings() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = StoreURLs(directory: directory)
        let failure = OneShotWriteFailure()
        let coordinator = PersistentStoreCoordinator(directory: directory, fileAccess: FailingAtomicFileAccess(failingWrite: { failure.shouldFail($0) }))
        try await coordinator.saveSettings(["mode": .string("original")])
        let original = try Data(contentsOf: urls.settings)
        failure.failNextWrite(to: "settings.json")
        do {
            try await coordinator.saveSettings(["mode": .string("replacement")])
            XCTFail("replacement write should fail")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: urls.settings), original)
        let state = try await coordinator.load()
        XCTAssertEqual(state.settings["mode"], .string("original"))
        try await coordinator.saveSettings(["mode": .string("replacement")])
        let replaced = try await PersistentStoreCoordinator(directory: directory).load()
        XCTAssertEqual(replaced.settings["mode"], .string("replacement"))
    }

    func testUnknownSchemaIsBackedUpBeforeDefaultsReplaceIt() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = StoreURLs(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data(#"{"schemaVersion":99,"value":{"future":"payload"}}"#.utf8)
        try original.write(to: urls.layouts)

        let state = try await PersistentStoreCoordinator(directory: directory).load()
        XCTAssertNotNil(state.layouts[PersistentStoreCoordinator.defaultLayoutID])
        let backup = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("layouts.json.") })
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertNotEqual(try Data(contentsOf: urls.layouts), original)
    }

    func testMalformedJSONAndInvalidGridAreBackedUpAndRecovered() async throws {
        for original in try invalidLayoutBytes() {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let urls = StoreURLs(directory: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try original.write(to: urls.layouts)

            let state = try await PersistentStoreCoordinator(directory: directory).load()
            XCTAssertNotNil(state.layouts[PersistentStoreCoordinator.defaultLayoutID])
            let backup = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("layouts.json.") })
            XCTAssertEqual(try Data(contentsOf: backup), original)
        }
    }

    func testReadFailureProtectsOriginalAndRejectsLaterWrites() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = StoreURLs(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("valid source bytes".utf8)
        try original.write(to: urls.layouts)
        let access = FailingAtomicFileAccess(failingWrite: { _ in false }, failingRead: { $0 == urls.layouts })
        let coordinator = PersistentStoreCoordinator(directory: directory, fileAccess: access)
        do {
            _ = try await coordinator.load()
            XCTFail("read failure must stop loading")
        } catch {}
        do {
            try await coordinator.saveLayouts([])
            XCTFail("unreadable store must remain protected")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: urls.layouts), original)
    }

    func testBackupFailureProtectsOriginalAndRejectsLaterWrites() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = StoreURLs(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("damaged".utf8)
        try original.write(to: urls.layouts)
        let access = FailingAtomicFileAccess(failingWrite: { $0.lastPathComponent.contains(".backup") })
        let coordinator = PersistentStoreCoordinator(directory: directory, fileAccess: access)

        do {
            _ = try await coordinator.load()
            XCTFail("load should fail when original data cannot be backed up")
        } catch {}
        do {
            try await coordinator.saveLayouts([])
            XCTFail("protected store must reject saves")
        } catch {
            XCTAssertTrue(error is PersistenceError)
        }
        XCTAssertEqual(try Data(contentsOf: urls.layouts), original)
    }

    func testDanglingAssignmentsAreBackedUpAndRemoved() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = StoreURLs(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let assignment = PersistedAssignment(displayUUID: UUID(), spaceScope: .common, layoutID: UUID())
        let encoder = JSONEncoder()
        let original = try encoder.encode(VersionedStore(schemaVersion: 1, value: AssignmentStore(assignments: [assignment])))
        try original.write(to: urls.assignments)

        let state = try await PersistentStoreCoordinator(directory: directory).load()
        XCTAssertTrue(state.assignments.isEmpty)
        let backup = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("assignments.json.") })
        XCTAssertEqual(try Data(contentsOf: backup), original)
        let repaired = try JSONDecoder().decode(VersionedStore<AssignmentStore>.self, from: Data(contentsOf: urls.assignments))
        XCTAssertTrue(repaired.value.assignments.isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func invalidLayoutBytes() throws -> [Data] {
        let malformed = Data("{not-json".utf8)
        let id = UUID()
        let invalidGrid: [String: Any] = [
            "id": id.uuidString, "kind": "grid", "rows": 1, "columns": 2,
            "rowPercentages": [10_000], "columnPercentages": [10_000],
            "cellChildMap": [[0, 1]], "spacing": 10, "template": LayoutTemplate.grid.rawValue,
            "zoneCount": 2
        ]
        let duplicateLayouts = [PersistentStoreCoordinator.defaultLayout(), PersistentStoreCoordinator.defaultLayout()]
        let encoder = JSONEncoder()
        let invalidGridStore = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "value": ["layouts": [invalidGrid]]
        ])
        let duplicateStore = try encoder.encode(VersionedStore(schemaVersion: 1, value: LayoutStore(layouts: duplicateLayouts)))
        return [malformed, invalidGridStore, duplicateStore]
    }
}

final class LayoutPersistenceControllerTests: XCTestCase {
    @MainActor
    func testRecalculateAndDisplayRefreshKeepSavedIDsAndBytes() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let displayUUID = UUID()
        let sessionID = UUID()
        let display = makeDisplay(runtimeID: 3, persistentUUID: displayUUID, sessionID: sessionID, primary: true)
        let disconnected = makeDisplay(runtimeID: 30, persistentUUID: displayUUID, sessionID: UUID(), primary: true)
        let reconnected = makeDisplay(runtimeID: 31, persistentUUID: displayUUID, sessionID: UUID(), primary: true)
        let temporary = makeDisplay(runtimeID: 31, persistentUUID: nil, sessionID: UUID(), primary: true)
        let returned = makeDisplay(runtimeID: 32, persistentUUID: displayUUID, sessionID: UUID(), primary: true)
        let secondaryUUID = UUID()
        let secondary = makeDisplay(runtimeID: 2, persistentUUID: secondaryUUID, sessionID: UUID(), primary: false)
        let coordinator = PersistentStoreCoordinator(directory: directory)
        let layout = PersistedLayout(
            id: id,
            definition: .grid(GridLayout(
                id: LayoutID(rawValue: id), rows: 1, columns: 2,
                rowPercentages: [10_000], columnPercentages: [5_000, 5_000], cellChildMap: [[8, 11]]
            )),
            spacing: 10, template: .columns, zoneCount: 2
        )
        try await coordinator.saveLayoutAndAssignments(
            [layout], [
                PersistedAssignment(displayUUID: displayUUID, spaceScope: .common, layoutID: id),
                PersistedAssignment(displayUUID: secondaryUUID, spaceScope: .common, layoutID: id)
            ]
        )
        let urls = StoreURLs(directory: directory)
        let layoutBytes = try Data(contentsOf: urls.layouts)
        let assignmentBytes = try Data(contentsOf: urls.assignments)
        let controller = LayoutController(
            displayProvider: DisplayProvider(snapshots: [
                DisplaySnapshot(displays: [display, secondary], primaryFrame: display.frame),
                DisplaySnapshot(displays: [disconnected], primaryFrame: disconnected.frame),
                DisplaySnapshot(displays: [reconnected, secondary], primaryFrame: reconnected.frame),
                DisplaySnapshot(displays: [temporary, secondary], primaryFrame: temporary.frame),
                DisplaySnapshot(displays: [returned, secondary], primaryFrame: returned.frame)
            ]),
            storeCoordinator: coordinator
        )
        await controller.loadPersistentState()
        let ids = controller.zones.map(\.id)
        controller.recalculate()
        controller.refreshDisplays()
        XCTAssertEqual(controller.zones.map(\.id), ids)
        XCTAssertEqual(controller.selectedDisplay?.runtimeID.rawValue, 30)
        controller.refreshDisplays()
        controller.refreshDisplays()
        XCTAssertEqual(controller.zones.map(\.id), [ZoneID(rawValue: 0), ZoneID(rawValue: 1), ZoneID(rawValue: 2), ZoneID(rawValue: 3)])
        XCTAssertEqual(controller.selectedDisplay?.sessionID, temporary.sessionID)
        controller.refreshDisplays()
        XCTAssertEqual(controller.selectedDisplay?.runtimeID.rawValue, 32)
        XCTAssertEqual(controller.zones.map(\.id), ids)
        let flushed = await controller.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(try Data(contentsOf: urls.layouts), layoutBytes)
        XCTAssertEqual(try Data(contentsOf: urls.assignments), assignmentBytes)
        let state = try await coordinator.load()
        XCTAssertEqual(state.assignments.count, 2)
        XCTAssertEqual(state.assignments[displayUUID]?.displayUUID, displayUUID)
        XCTAssertEqual(state.assignments[secondaryUUID]?.layoutID, id)
    }

    @MainActor
    func testEditingImplicitDefaultCopiesLayoutForOneDisplayOnly() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstID = UUID()
        let secondID = UUID()
        let first = makeDisplay(runtimeID: 1, persistentUUID: firstID, sessionID: UUID(), primary: true)
        let second = makeDisplay(runtimeID: 2, persistentUUID: secondID, sessionID: UUID(), primary: false)
        let coordinator = PersistentStoreCoordinator(directory: directory)
        let controller = LayoutController(
            displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [first, second], primaryFrame: first.frame)),
            storeCoordinator: coordinator
        )
        await controller.loadPersistentState()
        controller.template = .columns
        let flushed = await controller.flush()
        XCTAssertTrue(flushed)

        controller.selectDisplay(second.id)
        XCTAssertEqual(controller.zones.count, 4)
        let loaded = try await coordinator.load()
        XCTAssertNotEqual(loaded.assignments[firstID]?.layoutID, PersistentStoreCoordinator.defaultLayoutID)
        XCTAssertNil(loaded.assignments[secondID])
        XCTAssertEqual(loaded.layouts[loaded.assignments[firstID]!.layoutID]?.kind, .grid)
    }

    @MainActor
    func testEditingSharedCustomLayoutCopiesOnlySelectedDisplay() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstUUID = UUID()
        let secondUUID = UUID()
        let first = makeDisplay(runtimeID: 1, persistentUUID: firstUUID, sessionID: UUID(), primary: true)
        let second = makeDisplay(runtimeID: 2, persistentUUID: secondUUID, sessionID: UUID(), primary: false)
        let layoutID = UUID()
        let sharedLayout = PersistedLayout(
            id: layoutID,
            definition: .grid(GridLayout(
                id: LayoutID(rawValue: layoutID), rows: 1, columns: 2,
                rowPercentages: [10_000], columnPercentages: [5_000, 5_000], cellChildMap: [[6, 8]]
            )),
            spacing: 10, template: .columns, zoneCount: 2
        )
        let coordinator = PersistentStoreCoordinator(directory: directory)
        try await coordinator.saveLayoutAndAssignments(
            [sharedLayout], [
                PersistedAssignment(displayUUID: firstUUID, spaceScope: .common, layoutID: layoutID),
                PersistedAssignment(displayUUID: secondUUID, spaceScope: .common, layoutID: layoutID)
            ]
        )
        let controller = LayoutController(
            displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [first, second], primaryFrame: first.frame)),
            storeCoordinator: coordinator
        )
        await controller.loadPersistentState()
        controller.template = .rows
        let flushed = await controller.flush()
        XCTAssertTrue(flushed)
        controller.selectDisplay(second.id)
        XCTAssertEqual(controller.template, .columns)
        XCTAssertEqual(controller.zones.map(\.id), [ZoneID(rawValue: 6), ZoneID(rawValue: 8)])

        let state = try await coordinator.load()
        XCTAssertNotEqual(state.assignments[firstUUID]?.layoutID, layoutID)
        XCTAssertEqual(state.assignments[secondUUID]?.layoutID, layoutID)
        XCTAssertEqual(state.layouts[layoutID]?.template, LayoutTemplate.columns.rawValue)
        XCTAssertEqual(state.layouts[state.assignments[firstUUID]!.layoutID]?.template, LayoutTemplate.rows.rawValue)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDisplay(runtimeID: UInt32, persistentUUID: UUID?, sessionID: UUID, primary: Bool) -> Display {
        let frame = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        return Display(
            runtimeID: RuntimeDisplayID(rawValue: runtimeID),
            persistentID: persistentUUID.map { PersistentDisplayID(uuid: $0) },
            sessionID: sessionID, name: "Test display", frame: frame, workArea: frame,
            isPrimary: primary, backingScaleFactor: 2
        )
    }
}

final class LayoutPersistenceSaveTests: XCTestCase {
    @MainActor
    func testStaleSaveFailureDoesNotReplaceNewerUIRevision() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let displayUUID = UUID()
        let display = makeDisplay(runtimeID: 4, persistentUUID: displayUUID, sessionID: UUID(), primary: true)
        let failure = OneShotWriteFailure()
        let coordinator = PersistentStoreCoordinator(directory: directory, fileAccess: FailingAtomicFileAccess(failingWrite: { failure.shouldFail($0) }))
        let controller = LayoutController(
            displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)),
            storeCoordinator: coordinator
        )
        await controller.loadPersistentState()
        failure.failNextWrite(to: "layouts.json")
        controller.template = .rows
        controller.zoneCount = 3
        controller.spacing = 22

        let flushed = await controller.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(controller.template, .rows)
        XCTAssertEqual(controller.zoneCount, 3)
        XCTAssertEqual(controller.spacing, 22)
        XCTAssertEqual(controller.zones.map(\.id), [ZoneID(rawValue: 0), ZoneID(rawValue: 1), ZoneID(rawValue: 2)])
        let state = try await coordinator.load()
        let layoutID = try XCTUnwrap(state.assignments[displayUUID]?.layoutID)
        XCTAssertEqual(state.layouts[layoutID]?.template, LayoutTemplate.rows.rawValue)
        XCTAssertEqual(state.layouts[layoutID]?.zoneCount, 3)
        XCTAssertEqual(state.layouts[layoutID]?.spacing, 22)
    }

    @MainActor
    func testRapidControlUpdatesSaveInFIFOOrderAndRestoreFinalValues() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let displayUUID = UUID()
        let display = makeDisplay(runtimeID: 5, persistentUUID: displayUUID, sessionID: UUID(), primary: true)
        let writes = OneShotWriteFailure()
        let coordinator = PersistentStoreCoordinator(directory: directory, fileAccess: FailingAtomicFileAccess(failingWrite: { writes.shouldFail($0) }))
        let controller = LayoutController(
            displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)),
            storeCoordinator: coordinator
        )
        await controller.loadPersistentState()
        controller.template = .rows
        controller.zoneCount = 3
        controller.spacing = 20
        let flushed = await controller.flush()
        XCTAssertTrue(flushed)

        let state = try await coordinator.load()
        let layoutID = try XCTUnwrap(state.assignments[displayUUID]?.layoutID)
        XCTAssertEqual(state.layouts[layoutID]?.template, LayoutTemplate.rows.rawValue)
        XCTAssertEqual(state.layouts[layoutID]?.zoneCount, 3)
        XCTAssertEqual(state.layouts[layoutID]?.spacing, 20)
        XCTAssertEqual(controller.zones.map(\.id), [ZoneID(rawValue: 0), ZoneID(rawValue: 1), ZoneID(rawValue: 2)])
        XCTAssertEqual(writes.recordedWrites(), [
            "layouts.json", "assignments.json", "layouts.json", "assignments.json", "layouts.json", "assignments.json"
        ])
    }

    @MainActor
    func testSessionOnlyDisplayNeverPersistsSessionIdentity() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let display = makeDisplay(runtimeID: 7, persistentUUID: nil, sessionID: UUID(), primary: true)
        let coordinator = PersistentStoreCoordinator(directory: directory)
        let controller = LayoutController(
            displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)),
            storeCoordinator: coordinator
        )
        await controller.loadPersistentState()
        controller.template = .rows
        let flushed = await controller.flush()
        XCTAssertTrue(flushed)
        let urls = StoreURLs(directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls.assignments.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls.layouts.path))
    }

    @MainActor
    func testFailedPairedSaveKeepsErrorAndTerminationRetryCompletesPair() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let displayUUID = UUID()
        let display = makeDisplay(runtimeID: 8, persistentUUID: displayUUID, sessionID: UUID(), primary: true)
        let failure = OneShotWriteFailure()
        let coordinator = PersistentStoreCoordinator(directory: directory, fileAccess: FailingAtomicFileAccess(failingWrite: { failure.shouldFail($0) }))
        let controller = LayoutController(
            displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)),
            storeCoordinator: coordinator
        )
        await controller.loadPersistentState()
        failure.failNextWrite(to: "assignments.json")
        controller.template = .rows

        let firstFlush = await controller.prepareForTermination()
        XCTAssertTrue(firstFlush)
        XCTAssertFalse(controller.canRetrySave)
        let state = try await coordinator.load()
        let assignment = try XCTUnwrap(state.assignments[displayUUID])
        XCTAssertNotEqual(assignment.layoutID, PersistentStoreCoordinator.defaultLayoutID)
        XCTAssertEqual(state.layouts[assignment.layoutID]?.template, LayoutTemplate.rows.rawValue)
        XCTAssertEqual(Array(failure.recordedWrites().suffix(3)), ["assignments.json", "layouts.json", "assignments.json"])
    }

    @MainActor
    func testDeletePersistsUnassignmentBeforeLayoutAndRetriesAfterFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let displayUUID = UUID()
        let display = makeDisplay(runtimeID: 9, persistentUUID: displayUUID, sessionID: UUID(), primary: true)
        let failure = OneShotWriteFailure()
        let coordinator = PersistentStoreCoordinator(directory: directory, fileAccess: FailingAtomicFileAccess(failingWrite: { failure.shouldFail($0) }))
        let layoutID = UUID()
        let layout = PersistedLayout(
            id: layoutID,
            definition: .grid(GridLayout(
                id: LayoutID(rawValue: layoutID), rows: 1, columns: 1,
                rowPercentages: [10_000], columnPercentages: [10_000], cellChildMap: [[3]]
            )),
            spacing: 10, template: .grid, zoneCount: 1
        )
        try await coordinator.saveLayoutAndAssignments(
            [layout], [PersistedAssignment(displayUUID: displayUUID, spaceScope: .common, layoutID: layoutID)]
        )
        failure.clearWriteHistory()
        let controller = LayoutController(
            displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)),
            storeCoordinator: coordinator
        )
        await controller.loadPersistentState()
        failure.failNextWrite(to: "layouts.json")
        controller.deleteLayout(layoutID)

        let flushed = await controller.flush()
        XCTAssertTrue(flushed)
        let state = try await coordinator.load()
        XCTAssertNil(state.assignments[displayUUID])
        XCTAssertNil(state.layouts[layoutID])
        XCTAssertEqual(Array(failure.recordedWrites().suffix(4)), ["assignments.json", "layouts.json", "assignments.json", "layouts.json"])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDisplay(runtimeID: UInt32, persistentUUID: UUID?, sessionID: UUID, primary: Bool) -> Display {
        let frame = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        return Display(
            runtimeID: RuntimeDisplayID(rawValue: runtimeID),
            persistentID: persistentUUID.map { PersistentDisplayID(uuid: $0) },
            sessionID: sessionID, name: "Test display", frame: frame, workArea: frame,
            isPrimary: primary, backingScaleFactor: 2
        )
    }
}

private struct FailingAtomicFileAccess: AtomicFileAccess {
    let failingWrite: @Sendable (URL) -> Bool
    var failingRead: @Sendable (URL) -> Bool = { _ in false }

    func read(_ url: URL) throws -> Data? {
        if failingRead(url) { throw CocoaError(.fileReadUnknown) }
        return try LocalAtomicFileAccess().read(url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        if failingWrite(url) { throw CocoaError(.fileWriteUnknown) }
        try LocalAtomicFileAccess().writeAtomically(data, to: url)
    }

}

private final class OneShotWriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var pathSuffix: String?

    func failNextWrite(to suffix: String) {
        lock.lock()
        pathSuffix = suffix
        lock.unlock()
    }

    func shouldFail(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        writes.append(url.lastPathComponent)
        guard let pathSuffix, url.lastPathComponent == pathSuffix else { return false }
        self.pathSuffix = nil
        return true
    }

    private var writes: [String] = []

    func recordedWrites() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func clearWriteHistory() {
        lock.lock()
        writes.removeAll()
        lock.unlock()
    }
}
