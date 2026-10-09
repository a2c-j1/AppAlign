import CoreGraphics
import Foundation
import XCTest

final class LayoutEditorConcurrencyTests: XCTestCase {
    @MainActor
    func testQueuedSaveCopiesLayoutThatPrecedingApplyMadeActive() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let original = fixture.custom
        let edited = try named(original, "Edited after Apply")
        fixture.access.blockNextWrite("assignments.json")
        let applying = Task { await fixture.controller.applyEditorLayout(original.id, identity: fixture.identity()) }
        try await fixture.access.waitForBlockedWrite()
        let saving = Task { await fixture.controller.saveEditorLayout(edited, identity: fixture.identity()) }
        await allowQueuedOperationToRegister()
        fixture.access.releaseWrite()
        _ = try success(await applying.value)
        let saveResult = await saving.value
        let copy = try XCTUnwrap(try success(saveResult))
        let state = try await fixture.coordinator.load()
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(state.layouts[original.id], original)
        XCTAssertEqual(state.assignments[fixture.firstUUID]?.layoutID, original.id)
        XCTAssertEqual(try copy.definition(), try definition(original, id: copy.id))
    }

    @MainActor
    func testSupersededSaveStillPreservesItsSuccessfulDiskChange() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let first = layout(name: "First saved")
        let second = layout(name: "Second saved")
        let token = UUID()
        fixture.access.blockNextWrite("layouts.json")
        let earlier = Task { await fixture.controller.saveEditorLayout(first, identity: fixture.identity(token: token, revision: 1)) }
        try await fixture.access.waitForBlockedWrite()
        let later = Task { await fixture.controller.saveEditorLayout(second, identity: fixture.identity(token: token, revision: 2)) }
        await allowQueuedOperationToRegister()
        fixture.access.releaseWrite()
        if case .success = await earlier.value { XCTFail("An obsolete editor completion must not clear a newer draft.") }
        _ = try success(await later.value)
        let state = try await fixture.coordinator.load()
        XCTAssertEqual(state.layouts[first.id], first)
        XCTAssertEqual(state.layouts[second.id], second)
    }

    @MainActor
    func testSupersededApplyRefreshesRuntimeZonesEvenWhenLaterSaveFails() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let token = UUID()
        fixture.access.blockNextWrite("assignments.json")
        let applying = Task { await fixture.controller.applyEditorLayout(fixture.custom.id, identity: fixture.identity(token: token, revision: 1)) }
        try await fixture.access.waitForBlockedWrite()
        fixture.access.failNextWrite("layouts.json")
        let later = Task { await fixture.controller.saveEditorLayout(layout(name: "Will fail"), identity: fixture.identity(token: token, revision: 2)) }
        await allowQueuedOperationToRegister()
        fixture.access.releaseWrite()
        _ = await applying.value
        if case .success = await later.value { XCTFail("The injected save failure must be observed.") }
        let state = try await fixture.coordinator.load()
        XCTAssertEqual(state.assignments[fixture.firstUUID]?.layoutID, fixture.custom.id)
        XCTAssertEqual(fixture.controller.zones, try LayoutEngine.zones(for: fixture.custom.definition(), in: fixture.first.workArea, spacing: fixture.custom.spacing))
    }

    @MainActor
    func testDeleteQueuedBehindSaveRetainsNewLayoutAndOtherDisplayAssignment() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let added = layout(name: "Keep queued save")
        fixture.access.blockNextWrite("layouts.json")
        let saving = Task { await fixture.controller.saveEditorLayout(added, identity: fixture.identity()) }
        try await fixture.access.waitForBlockedWrite()
        let deleting = Task { await fixture.controller.deleteEditorLayout(fixture.custom.id, identity: fixture.identity()) }
        await allowQueuedOperationToRegister()
        fixture.access.releaseWrite()
        _ = try success(await saving.value)
        _ = try success(await deleting.value)
        let state = try await fixture.coordinator.load()
        XCTAssertEqual(state.layouts[added.id], added)
        XCTAssertNil(state.layouts[fixture.custom.id])
        XCTAssertEqual(state.assignments[fixture.secondUUID]?.layoutID, fixture.other.id)
    }

    @MainActor
    func testSaveFailureKeepsDraftUndoAndCancelLeavesStoreAndAppliedZonesUnchanged() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try success(await fixture.controller.applyEditorLayout(fixture.custom.id, identity: fixture.identity()))
        let urls = StoreURLs(directory: fixture.directory)
        let beforeLayouts = try Data(contentsOf: urls.layouts)
        let beforeAssignments = try Data(contentsOf: urls.assignments)
        let beforeZones = fixture.controller.zones
        let model = LayoutEditorModel(layout: fixture.custom, workArea: fixture.first.workArea)
        model.setName("Keep unsaved input")
        fixture.access.failNextWrite("layouts.json")
        if case .success = await fixture.controller.saveEditorLayout(model.draft, identity: fixture.identity()) {
            XCTFail("The failed Save must not be reported as successful.")
        }
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(model.canUndo)
        XCTAssertEqual(model.draft.name, "Keep unsaved input")
        model.cancel()
        XCTAssertEqual(model.draft, fixture.custom)
        XCTAssertEqual(try Data(contentsOf: urls.layouts), beforeLayouts)
        XCTAssertEqual(try Data(contentsOf: urls.assignments), beforeAssignments)
        XCTAssertEqual(fixture.controller.zones, beforeZones)
    }

    @MainActor
    func testRetryOfOlderFailedSaveCannotEraseNewChangesOnAnotherDisplay() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        fixture.access.failNextWrite("assignments.json")
        fixture.controller.template = .rows
        for _ in 0 ..< 200 where !fixture.controller.canRetrySave {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(fixture.controller.canRetrySave, "The legacy paired-save failure must be captured before the newer edit.")
        let newer = layout(name: "Display B newer layout")
        _ = try success(await fixture.controller.saveEditorLayout(newer, identity: fixture.identity(display: fixture.second.id)))
        _ = try success(await fixture.controller.applyEditorLayout(newer.id, identity: fixture.identity(display: fixture.second.id)))
        _ = await fixture.controller.retryFailedSave()
        let state = try await fixture.coordinator.load()
        XCTAssertEqual(state.layouts[newer.id], newer)
        XCTAssertEqual(state.assignments[fixture.secondUUID]?.layoutID, newer.id)
    }

    @MainActor
    func testSecondDeleteWriteFailureReportsPartialStateAndRetryPreservesOtherDisplay() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try success(await fixture.controller.applyEditorLayout(fixture.custom.id, identity: fixture.identity()))
        fixture.access.failNextWrite("layouts.json")
        if case .success = await fixture.controller.deleteEditorLayout(fixture.custom.id, identity: fixture.identity()) {
            XCTFail("The second write failure must not report complete deletion.")
        }
        let partial = try await fixture.coordinator.load()
        XCTAssertNil(partial.assignments[fixture.firstUUID])
        XCTAssertEqual(partial.layouts[fixture.custom.id], fixture.custom)
        XCTAssertEqual(fixture.controller.zones, try LayoutEngine.zones(for: PersistentStoreCoordinator.defaultLayout().definition(), in: fixture.first.workArea, spacing: 10))
        _ = try success(await fixture.controller.deleteEditorLayout(fixture.custom.id, identity: fixture.identity()))
        let completed = try await fixture.coordinator.load()
        XCTAssertNil(completed.layouts[fixture.custom.id])
        XCTAssertEqual(completed.assignments[fixture.secondUUID]?.layoutID, fixture.other.id)
    }

    @MainActor
    func testAcceptanceLayoutsSaveReloadAndCancelWithoutChangingAppliedDefinition() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let appliedZones = fixture.controller.zones
        let columns = layout(name: "25/50/25")
        guard case .grid(let grid) = try columns.definition() else { throw CocoaError(.coderInvalidValue) }
        let merged = try LayoutEditing.merge(grid, zoneIDs: [7, 15])
        let mergedID = UUID()
        let mergedLayout = PersistedLayout(
            id: mergedID,
            definition: .grid(GridLayout(id: LayoutID(rawValue: mergedID), rows: merged.rows, columns: merged.columns,
                                         rowPercentages: merged.rowPercentages, columnPercentages: merged.columnPercentages,
                                         cellChildMap: merged.cellChildMap)),
            spacing: 0, template: .grid, zoneCount: 2, name: "Merged Grid"
        )
        let canvasID = UUID()
        let canvas = CanvasLayout(id: LayoutID(rawValue: canvasID), referenceSize: CGSize(width: 1_000, height: 700), zones: [
            CanvasZone(id: ZoneID(rawValue: 20), frame: CGRect(x: 50, y: 50, width: 600, height: 450)),
            CanvasZone(id: ZoneID(rawValue: 50), frame: CGRect(x: 250, y: 150, width: 650, height: 500))
        ])
        let overlap = PersistedLayout(id: canvasID, definition: .canvas(canvas), spacing: 0, template: .grid, zoneCount: 2, name: "Overlap")
        for candidate in [columns, mergedLayout, overlap] {
            _ = try success(await fixture.controller.saveEditorLayout(candidate, identity: fixture.identity()))
        }
        let reloaded = try await PersistentStoreCoordinator(directory: fixture.directory).load()
        let urls = StoreURLs(directory: fixture.directory)
        let layoutsBytes = try Data(contentsOf: urls.layouts)
        let assignmentsBytes = try Data(contentsOf: urls.assignments)
        for candidate in [columns, mergedLayout, overlap] {
            let restored = try XCTUnwrap(reloaded.layouts[candidate.id])
            XCTAssertEqual(restored, candidate)
            XCTAssertEqual(try restored.definition(), try candidate.definition())
            let model = LayoutEditorModel(layout: restored, workArea: fixture.first.workArea)
            model.setName("Unsaved change")
            XCTAssertTrue(model.isDirty)
            model.cancel()
            XCTAssertEqual(model.draft, restored)
        }
        XCTAssertEqual(try Data(contentsOf: urls.layouts), layoutsBytes)
        XCTAssertEqual(try Data(contentsOf: urls.assignments), assignmentsBytes)
        XCTAssertEqual(fixture.controller.zones, appliedZones)
        XCTAssertEqual(fixture.controller.editorCatalog(for: fixture.first.id).appliedLayoutID, PersistentStoreCoordinator.defaultLayoutID)
    }

    @MainActor
    private func makeFixture(includeDefault: Bool = true) async throws -> EditorFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Issue5Review-\(UUID().uuidString)", isDirectory: true)
        let access = EditorControlledFileAccess()
        let coordinator = PersistentStoreCoordinator(directory: directory, fileAccess: access)
        let firstUUID = UUID()
        let secondUUID = UUID()
        let first = display(uuid: firstUUID, runtimeID: 1, primary: true)
        let second = display(uuid: secondUUID, runtimeID: 2, primary: false)
        let custom = layout(name: "Custom")
        let other = layout(name: "Other display")
        try await coordinator.saveLayoutAndAssignments(
            (includeDefault ? [PersistentStoreCoordinator.defaultLayout()] : []) + [custom, other],
            [PersistedAssignment(displayUUID: secondUUID, spaceScope: .common, layoutID: other.id)]
        )
        let controller = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [first, second], primaryFrame: first.frame)), storeCoordinator: coordinator)
        await controller.loadPersistentState()
        return EditorFixture(directory: directory, access: access, coordinator: coordinator, controller: controller,
                             first: first, second: second, firstUUID: firstUUID, secondUUID: secondUUID, custom: custom, other: other)
    }

    private func layout(name: String) -> PersistedLayout {
        let id = UUID()
        let grid = GridLayout(id: LayoutID(rawValue: id), rows: 1, columns: 3, rowPercentages: [10_000],
                              columnPercentages: [2_500, 5_000, 2_500], cellChildMap: [[7, 15, 1_000]])
        return PersistedLayout(id: id, definition: .grid(grid), spacing: 0, template: .columns, zoneCount: 3, name: name)
    }

    private func named(_ layout: PersistedLayout, _ name: String) throws -> PersistedLayout {
        PersistedLayout(id: layout.id, definition: try layout.definition(), spacing: layout.spacing,
                        template: LayoutTemplate(rawValue: layout.template) ?? .grid, zoneCount: layout.zoneCount, name: name)
    }

    private func definition(_ layout: PersistedLayout, id: UUID) throws -> LayoutDefinition {
        guard case .grid(let grid) = try layout.definition() else { throw CocoaError(.coderInvalidValue) }
        return .grid(GridLayout(id: LayoutID(rawValue: id), rows: grid.rows, columns: grid.columns,
                                rowPercentages: grid.rowPercentages, columnPercentages: grid.columnPercentages, cellChildMap: grid.cellChildMap))
    }

    private func display(uuid: UUID, runtimeID: UInt32, primary: Bool) -> Display {
        let frame = CGRect(x: primary ? 0 : 1_000, y: 0, width: 1_000, height: 700)
        return Display(runtimeID: RuntimeDisplayID(rawValue: runtimeID), persistentID: PersistentDisplayID(uuid: uuid),
                       sessionID: UUID(), name: primary ? "A" : "B", frame: frame, workArea: frame, isPrimary: primary, backingScaleFactor: 2)
    }

    private func success(_ result: EditorOperationResult) throws -> PersistedLayout? {
        switch result {
        case .success(let layout): return layout
        case .failure(let message): XCTFail(message); throw CocoaError(.fileWriteUnknown)
        }
    }

    @MainActor
    private func allowQueuedOperationToRegister() async {
        // The actor performing the file write remains blocked while MainActor registers the next request.
        try? await Task.sleep(for: .milliseconds(50))
    }
}

extension LayoutEditorConcurrencyTests {
    @MainActor
    func testQueuedRenameChangesOnlyNameOfLatestSavedDefinition() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        guard case .grid(let grid) = try fixture.custom.definition() else { throw CocoaError(.coderInvalidValue) }
        let resizedGrid = try LayoutEditing.setPercentages([3_000, 4_000, 3_000], axis: .columns, on: grid)
        let changed = PersistedLayout(id: fixture.custom.id, definition: .grid(resizedGrid), spacing: 12,
                                      template: .columns, zoneCount: 3, name: "Saved geometry")
        fixture.access.blockNextWrite("layouts.json")
        let saving = Task { await fixture.controller.saveEditorLayout(changed, identity: fixture.identity()) }
        try await fixture.access.waitForBlockedWrite()
        let renaming = Task { await fixture.controller.renameEditorLayout(changed.id, to: "Renamed", identity: fixture.identity()) }
        await allowQueuedOperationToRegister()
        fixture.access.releaseWrite()
        _ = try success(await saving.value)
        _ = try success(await renaming.value)
        let state = try await fixture.coordinator.load()
        let restored = try XCTUnwrap(state.layouts[changed.id])
        XCTAssertEqual(try restored.definition(), try changed.definition())
        XCTAssertEqual(restored.spacing, changed.spacing)
        XCTAssertEqual(restored.name, "Renamed")
    }

    @MainActor
    func testApplyImplicitDefaultDoesNotCreateDanglingAssignment() async throws {
        let fixture = try await makeFixture(includeDefault: false)
        defer { fixture.remove() }
        _ = try success(await fixture.controller.applyEditorLayout(PersistentStoreCoordinator.defaultLayoutID, identity: fixture.identity()))
        let state = try await fixture.coordinator.load()
        if let assignment = state.assignments[fixture.firstUUID] {
            XCTAssertNotNil(state.layouts[assignment.layoutID])
            XCTAssertEqual(assignment.layoutID, PersistentStoreCoordinator.defaultLayoutID)
        }
        XCTAssertEqual(fixture.controller.editorCatalog(for: fixture.first.id).appliedLayoutID, PersistentStoreCoordinator.defaultLayoutID)
        XCTAssertEqual(fixture.controller.zones, try LayoutEngine.zones(for: PersistentStoreCoordinator.defaultLayout().definition(), in: fixture.first.workArea, spacing: 10))
    }

    @MainActor
    func testApplyingLayoutsToNonselectedDisplayAtoBtoAAdvancesDragRevision() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        XCTAssertNotEqual(fixture.controller.selectedDisplayID, fixture.second.id)

        let initialRevision = fixture.controller.dragLayoutRevision
        _ = try success(await fixture.controller.applyEditorLayout(fixture.custom.id, identity: fixture.identity(display: fixture.second.id)))
        let revisionB = fixture.controller.dragLayoutRevision
        XCTAssertGreaterThan(revisionB, initialRevision)

        _ = try success(await fixture.controller.applyEditorLayout(fixture.other.id, identity: fixture.identity(display: fixture.second.id)))
        let revisionA = fixture.controller.dragLayoutRevision
        XCTAssertGreaterThan(revisionA, revisionB)

        _ = try success(await fixture.controller.applyEditorLayout(fixture.custom.id, identity: fixture.identity(display: fixture.second.id)))
        XCTAssertGreaterThan(fixture.controller.dragLayoutRevision, revisionA)
        XCTAssertNotEqual(fixture.controller.selectedDisplayID, fixture.second.id)
    }
}

@MainActor
private struct EditorFixture {
    let directory: URL
    let access: EditorControlledFileAccess
    let coordinator: PersistentStoreCoordinator
    let controller: LayoutController
    let first: Display
    let second: Display
    let firstUUID: UUID
    let secondUUID: UUID
    let custom: PersistedLayout
    let other: PersistedLayout

    func identity(token: UUID = UUID(), revision: UInt64 = 1, display: DisplaySelectionID? = nil) -> EditorOperationIdentity {
        EditorOperationIdentity(token: token, targetDisplay: display ?? first.id, revision: revision)
    }

    func remove() { access.releaseWrite(); try? FileManager.default.removeItem(at: directory) }
}

private final class EditorControlledFileAccess: AtomicFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private var blockedName: String?
    private var failedName: String?

    func blockNextWrite(_ name: String) { lock.withLock { blockedName = name } }
    func failNextWrite(_ name: String) { lock.withLock { failedName = name } }
    func releaseWrite() { released.signal() }

    func waitForBlockedWrite() async throws {
        let entered = await Task.detached { self.waitForEntrySynchronously() }.value
        guard entered else { throw CocoaError(.fileWriteUnknown) }
    }

    private func waitForEntrySynchronously() -> Bool { entered.wait(timeout: .now() + 5) == .success }

    func read(_ url: URL) throws -> Data? { try LocalAtomicFileAccess().read(url) }

    func writeAtomically(_ data: Data, to url: URL) throws {
        let flags = lock.withLock {
            let block = blockedName == url.lastPathComponent
            let fail = failedName == url.lastPathComponent
            if block { blockedName = nil }
            if fail { failedName = nil }
            return (block, fail)
        }
        if flags.0 {
            entered.signal()
            guard released.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileWriteUnknown) }
        }
        if flags.1 { throw CocoaError(.fileWriteUnknown) }
        try LocalAtomicFileAccess().writeAtomically(data, to: url)
    }
}
