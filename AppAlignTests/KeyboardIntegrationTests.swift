import CoreGraphics
import Foundation
import XCTest

final class KeyboardIntegrationTests: XCTestCase {
    @MainActor
    func testSettingsFailureSurvivesEditorSuccessAndTerminationRetriesLatestSettings() async throws {
        let fixture = try await IntegrationFixture.make()
        defer { fixture.remove() }
        fixture.access.failNextSettingsWrite()
        var settings = fixture.controller.keyboardSettings
        settings.isEnabled = true
        fixture.controller.updateKeyboardSettings(settings)
        await fixture.controller.saveChain?.value
        XCTAssertNotNil(fixture.controller.keyboardSettingsErrorMessage)

        _ = try requireSuccess(await fixture.controller.saveEditorLayout(fixture.firstLayout, identity: fixture.identity()))
        XCTAssertNotNil(fixture.controller.keyboardSettingsErrorMessage, "Editor success must not clear the keyboard save failure.")
        let ready = await fixture.controller.prepareForTermination()
        XCTAssertTrue(ready)
        let loaded = try await fixture.coordinator.load()
        XCTAssertEqual(loaded.settings["keyboard.enabled"], .bool(true))
        XCTAssertEqual(loaded.settings["unrelated"], .string("keep"))
        XCTAssertNil(fixture.controller.keyboardSettingsErrorMessage)
    }

    @MainActor
    func testQueuedOldRetryCannotOverwriteNewerSettingsOrAppliedAssignment() async throws {
        let fixture = try await IntegrationFixture.make()
        defer { fixture.access.releaseWrite(); fixture.remove() }
        fixture.access.failNextSettingsWrite()
        var first = fixture.controller.keyboardSettings
        first.cyclesAtEdges = false
        fixture.controller.updateKeyboardSettings(first)
        await fixture.controller.saveChain?.value

        fixture.access.blockNextLayoutWrite()
        let saving = Task { await fixture.controller.saveEditorLayout(fixture.secondLayout, identity: fixture.identity()) }
        try await fixture.access.waitForBlockedWrite()
        var retryStarted = false
        let retry = Task {
            retryStarted = true
            return await fixture.controller.retryKeyboardSettingsSave()
        }
        for _ in 0 ..< 200 where !retryStarted { await Task.yield() }
        guard retryStarted else { throw IntegrationTestError.barrierTimedOut }
        var newest = first
        newest.cyclesAtEdges = true
        newest.mode = .zoneOrder
        fixture.controller.updateKeyboardSettings(newest)
        fixture.access.releaseWrite()
        _ = try requireSuccess(await saving.value)
        _ = await retry.value
        let flushed = await fixture.controller.flush()
        XCTAssertTrue(flushed)
        let loaded = try await fixture.coordinator.load()
        XCTAssertEqual(loaded.settings["keyboard.cycle"], .bool(true))
        XCTAssertEqual(loaded.settings["keyboard.mode"], .string(NavigationMode.zoneOrder.rawValue))
        XCTAssertEqual(loaded.assignments[fixture.first.persistentID!.uuid]?.layoutID, fixture.firstLayout.id)
        XCTAssertEqual(fixture.access.settingsWriteCount, 2, "The superseded retry must not write its stale snapshot.")
    }

    @MainActor
    func testPendingReloadAndRetryKeepUnknownKeyboardAndUnrelatedKeys() async throws {
        let fixture = try await IntegrationFixture.make()
        defer { fixture.remove() }
        fixture.access.failNextSettingsWrite()
        var updated = fixture.controller.keyboardSettings
        updated.isEnabled = true
        fixture.controller.updateKeyboardSettings(updated)
        await fixture.controller.saveChain?.value
        fixture.controller.adoptSettings([
            "unrelated": .string("newer unrelated value"),
            "keyboard.futureFeature": .string("future version"),
            "keyboard.enabled": .bool(false)
        ])
        let retried = await fixture.controller.retryKeyboardSettingsSave()
        XCTAssertTrue(retried)
        let loaded = try await fixture.coordinator.load()
        XCTAssertEqual(loaded.settings["keyboard.enabled"], .bool(true))
        XCTAssertEqual(loaded.settings["keyboard.futureFeature"], .string("future version"))
        XCTAssertEqual(loaded.settings["unrelated"], .string("newer unrelated value"))
    }

    @MainActor
    func testTargetDisplaySnapshotDoesNotFollowSelectedEditorDisplay() async throws {
        let fixture = try await IntegrationFixture.make()
        defer { fixture.remove() }
        fixture.controller.selectDisplay(fixture.first.id)
        let snapshot = try XCTUnwrap(fixture.controller.appliedLayoutSnapshot(for: fixture.second.frame))
        XCTAssertEqual(snapshot.display.id, fixture.second.id)
        XCTAssertEqual(snapshot.layout.id, fixture.secondLayout.id)
        XCTAssertEqual(snapshot.zones.map(\.id.rawValue), [8, 11])
        XCTAssertEqual(fixture.controller.selectedDisplayID, fixture.first.id)
        let loaded = try await fixture.coordinator.load()
        XCTAssertEqual(loaded.assignments[fixture.first.persistentID!.uuid]?.layoutID, fixture.firstLayout.id)
        XCTAssertEqual(loaded.assignments[fixture.second.persistentID!.uuid]?.layoutID, fixture.secondLayout.id)
    }

    @MainActor
    func testDraftAndSaveLeaveSnapshotUnchangedUntilApply() async throws {
        let fixture = try await IntegrationFixture.make()
        defer { fixture.remove() }
        let before = try XCTUnwrap(fixture.controller.appliedLayoutSnapshot(for: fixture.first.frame))
        let editor = LayoutEditorModel(layout: fixture.firstLayout, workArea: fixture.first.workArea)
        editor.setSpacing(20)
        XCTAssertTrue(editor.isDirty)
        XCTAssertEqual(fixture.controller.appliedLayoutSnapshot(for: fixture.first.frame), before)
        let saved = try requireSuccess(await fixture.controller.saveEditorLayout(editor.draft, identity: fixture.identity()))
        XCTAssertNotEqual(saved.id, fixture.firstLayout.id)
        XCTAssertEqual(fixture.controller.appliedLayoutSnapshot(for: fixture.first.frame), before)
        _ = try requireSuccess(await fixture.controller.applyEditorLayout(saved.id, identity: fixture.identity()))
        let applied = try XCTUnwrap(fixture.controller.appliedLayoutSnapshot(for: fixture.first.frame))
        XCTAssertEqual(applied.layout.id, saved.id)
        XCTAssertNotEqual(applied.zones, before.zones)
        XCTAssertFalse(fixture.controller.isCurrent(before, for: fixture.first.frame))
    }

    @MainActor
    func testSessionDisplayUsesAppliedSessionLayoutWithoutPersistentAssignment() async throws {
        let fixture = try await IntegrationFixture.make(secondIsSession: true)
        defer { fixture.remove() }
        _ = try requireSuccess(await fixture.controller.applyEditorLayout(fixture.secondLayout.id, identity: fixture.identity(display: fixture.second.id)))
        let snapshot = try XCTUnwrap(fixture.controller.appliedLayoutSnapshot(for: fixture.second.frame))
        XCTAssertEqual(snapshot.layout.id, fixture.secondLayout.id)
        XCTAssertEqual(snapshot.zones.map(\.id.rawValue), [8, 11])
        XCTAssertNil(snapshot.display.persistentID)
        let loaded = try await fixture.coordinator.load()
        XCTAssertEqual(loaded.assignments.count, 1)
        XCTAssertEqual(fixture.controller.keyboardZoneChoices.map(\.rawValue), [0, 1, 2, 3, 8, 11])
    }

    private func requireSuccess(_ result: EditorOperationResult) throws -> PersistedLayout {
        switch result {
        case .success(let layout): try XCTUnwrap(layout)
        case .failure(let message): throw IntegrationTestError.operationFailed(message)
        }
    }
}

private enum IntegrationTestError: Error {
    case operationFailed(String)
    case barrierTimedOut
}

@MainActor
private struct IntegrationFixture {
    let directory: URL
    let access: IntegrationFileAccess
    let coordinator: PersistentStoreCoordinator
    let controller: LayoutController
    let first: Display
    let second: Display
    let firstLayout: PersistedLayout
    let secondLayout: PersistedLayout

    static func make(secondIsSession: Bool = false) async throws -> IntegrationFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Issue6-integration-\(UUID().uuidString)")
        let access = IntegrationFileAccess()
        let coordinator = PersistentStoreCoordinator(directory: directory, fileAccess: access)
        let first = display(1, originX: 0, persistent: true)
        let second = display(2, originX: 1_000, persistent: !secondIsSession)
        let firstLayout = PersistentStoreCoordinator.defaultLayout()
        let id = UUID()
        let secondLayout = PersistedLayout(id: id, definition: .grid(GridLayout(
            id: LayoutID(rawValue: id), rows: 1, columns: 2, rowPercentages: [10_000],
            columnPercentages: [2_500, 7_500], cellChildMap: [[8, 11]]
        )), spacing: 10, template: .columns, zoneCount: 2)
        var assignments = [PersistedAssignment(displayUUID: first.persistentID!.uuid, spaceScope: .common, layoutID: firstLayout.id)]
        if let uuid = second.persistentID?.uuid {
            assignments.append(PersistedAssignment(displayUUID: uuid, spaceScope: .common, layoutID: secondLayout.id))
        }
        try await coordinator.saveLayoutAndAssignments([firstLayout, secondLayout], assignments)
        try await coordinator.saveSettings(["unrelated": .string("keep")])
        access.resetWriteCount()
        let provider = DisplayProvider(snapshot: DisplaySnapshot(displays: [first, second], primaryFrame: first.frame))
        let controller = LayoutController(displayProvider: provider, storeCoordinator: coordinator)
        await controller.loadPersistentState()
        return IntegrationFixture(directory: directory, access: access, coordinator: coordinator, controller: controller,
                                  first: first, second: second, firstLayout: firstLayout, secondLayout: secondLayout)
    }

    func identity(display: DisplaySelectionID? = nil) -> EditorOperationIdentity {
        EditorOperationIdentity(token: UUID(), targetDisplay: display ?? first.id, revision: 1)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private static func display(_ runtimeID: UInt32, originX: CGFloat, persistent: Bool) -> Display {
        let frame = CGRect(x: originX, y: 0, width: 1_000, height: 800)
        return Display(runtimeID: RuntimeDisplayID(rawValue: runtimeID), persistentID: persistent ? PersistentDisplayID(uuid: UUID()) : nil,
                       sessionID: UUID(), name: "Test display", frame: frame, workArea: frame, isPrimary: runtimeID == 1, backingScaleFactor: 1)
    }
}

/// The lock protects all mutable test-control state; the semaphore only blocks the injected file writer.
private final class IntegrationFileAccess: AtomicFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var failSettings = false
    private var blockLayout = false
    private var blocked = false
    private var settingsWrites = 0

    var settingsWriteCount: Int { lock.withLock { settingsWrites } }
    func resetWriteCount() { lock.withLock { settingsWrites = 0 } }
    func failNextSettingsWrite() { lock.withLock { failSettings = true } }
    func blockNextLayoutWrite() { lock.withLock { blockLayout = true; blocked = false } }
    func releaseWrite() { gate.signal() }

    func waitForBlockedWrite() async throws {
        for _ in 0 ..< 200 {
            if lock.withLock({ blocked }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw IntegrationTestError.barrierTimedOut
    }

    func read(_ url: URL) throws -> Data? { try LocalAtomicFileAccess().read(url) }

    func writeAtomically(_ data: Data, to url: URL) throws {
        let (shouldFail, shouldBlock) = lock.withLock {
            if url.lastPathComponent == "settings.json" {
                settingsWrites += 1
                if failSettings { failSettings = false; return (true, false) }
            }
            if url.lastPathComponent == "layouts.json", blockLayout {
                blockLayout = false
                blocked = true
                return (false, true)
            }
            return (false, false)
        }
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
        if shouldBlock, gate.wait(timeout: .now() + 5) == .timedOut { throw IntegrationTestError.barrierTimedOut }
        try LocalAtomicFileAccess().writeAtomically(data, to: url)
    }
}
