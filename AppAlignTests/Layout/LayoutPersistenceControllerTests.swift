import XCTest

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
