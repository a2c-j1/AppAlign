import AppKit
import Foundation
import XCTest

final class SpaceProviderTests: XCTestCase {
    @MainActor
    func testValidatedBackendProducesPerDisplayPersistentSpaceSnapshots() async throws {
        let firstDisplay = UUID()
        let secondDisplay = UUID()
        let provider = SpaceProvider(backend: FakeValidatedSpaceBackend())
        provider.requestScopedMode()

        let snapshots = await refreshSpaceProvider(provider, displays: [firstDisplay, secondDisplay])

        XCTAssertEqual(provider.mode, .validatedScoped)
        let expectedID = try XCTUnwrap(PersistentSpaceID(backend: "fake", opaqueID: firstDisplay.uuidString))
        XCTAssertEqual(snapshots[firstDisplay]?.persistedScope, .space(expectedID))
        XCTAssertNotEqual(snapshots[firstDisplay]?.persistedScope, snapshots[secondDisplay]?.persistedScope)
        XCTAssertTrue(snapshots[firstDisplay]?.recordsHistory == true)
        XCTAssertTrue(snapshots[firstDisplay]?.allowsAutomaticRestore == true)
    }

    @MainActor
    func testCommonOnlyAndDegradedScopedKeepDifferentHistoryPolicies() async {
        let display = UUID()
        let provider = SpaceProvider(backend: FakeFailedSpaceBackend())

        let common = await refreshSpaceProvider(provider, displays: [display])[display]
        XCTAssertEqual(common?.mode, .commonOnly)
        XCTAssertEqual(common?.persistedScope, .common)
        XCTAssertTrue(common?.recordsHistory == true)
        XCTAssertTrue(common?.allowsAutomaticRestore == true)

        provider.requestScopedMode()
        let degraded = await refreshSpaceProvider(provider, displays: [display])[display]
        XCTAssertEqual(degraded?.mode, .degradedScoped)
        XCTAssertEqual(degraded?.persistedScope, .common)
        XCTAssertFalse(degraded?.recordsHistory ?? true)
        XCTAssertFalse(degraded?.allowsAutomaticRestore ?? true)
    }

    @MainActor
    func testIntentionalCommonOnlyModeDoesNotReenableScopedBackend() async {
        let display = UUID()
        let provider = SpaceProvider(backend: FakeValidatedSpaceBackend())
        provider.requestScopedMode()
        let scoped = await refreshSpaceProvider(provider, displays: [display])
        XCTAssertEqual(scoped[display]?.mode, .validatedScoped)

        provider.useCommonOnlyMode()

        let common = await refreshSpaceProvider(provider, displays: [display])
        XCTAssertEqual(common[display]?.mode, .commonOnly)
        XCTAssertEqual(provider.mode, .commonOnly)
    }

    @MainActor
    func testCandidateReadDoesNotPublishAndStaleIntentCannotCommit() async {
        let display = UUID()
        let provider = SpaceProvider(backend: FakeValidatedSpaceBackend())
        provider.requestScopedMode()
        let request = provider.makeRefreshRequest(displays: [display])
        let candidate = await provider.readCandidate(for: request)

        XCTAssertEqual(provider.mode, .commonOnly)
        XCTAssertTrue(provider.snapshots.isEmpty)

        provider.useCommonOnlyMode()

        XCTAssertFalse(provider.publish(candidate, for: request))
        XCTAssertEqual(provider.mode, .commonOnly)
        XCTAssertTrue(provider.snapshots.isEmpty)
    }

    @MainActor
    func testDisplayPublishReloadsManualLayoutWhenOnlySpaceScopeChanges() async throws {
        let displayUUID = UUID()
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1),
                              persistentID: PersistentDisplayID(uuid: displayUUID), sessionID: UUID(),
                              name: "Test", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 780), isPrimary: true,
                              backingScaleFactor: 1)
        let defaultLayout = PersistentStoreCoordinator.defaultLayout()
        let layoutA = testLayout(name: "Space A", columns: 2)
        let layoutB = testLayout(name: "Space B", columns: 3)
        let spaceA = try XCTUnwrap(PersistentSpaceID(backend: "fake", opaqueID: "A"))
        let spaceB = try XCTUnwrap(PersistentSpaceID(backend: "fake", opaqueID: "B"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStoreCoordinator(directory: directory)
        try await store.saveLayoutAndAssignments([defaultLayout, layoutA, layoutB], [
            PersistedAssignment(displayUUID: displayUUID, spaceScope: .common, layoutID: defaultLayout.id),
            PersistedAssignment(displayUUID: displayUUID, spaceScope: .space(spaceA), layoutID: layoutA.id),
            PersistedAssignment(displayUUID: displayUUID, spaceScope: .space(spaceB), layoutID: layoutB.id)
        ])
        let backend = SwitchingSpaceBackend()
        let provider = SpaceProvider.production(backend: backend)
        _ = await refreshSpaceProvider(provider, displays: [displayUUID])
        let snapshot = DisplaySnapshot(displays: [display], primaryFrame: display.frame)
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: snapshot), spaceProvider: provider,
                                      storeCoordinator: store)
        await layout.loadPersistentState()
        layout.displaysDidPublish(snapshot)
        XCTAssertEqual(layout.currentLayout.id, layoutA.id)
        XCTAssertEqual(layout.editorCatalog(for: display.id).appliedLayoutID, layoutA.id,
                       "The production provider factory must flow through controller resolver and editor eligibility.")
        layout.recordAppZoneHistory(key: AppZoneHistoryKey(bundleID: "com.example.Space", displayUUID: displayUUID,
                                                           spaceScope: .space(spaceA), layoutID: layoutA.id),
                                    expectedLayout: layoutA, zoneIDs: [0])
        let scopedLease = layout.reserveAppPlacement(token: RuntimeWindowToken(id: UUID(), pid: 42),
                                                     bundleID: "com.example.Space", display: display,
                                                     layout: layoutA)
        XCTAssertNotNil(scopedLease, "Validated scope must reserve history under the selected Space key.")
        XCTAssertEqual(scopedLease?.key.spaceScope, .space(spaceA))
        layout.releaseAppPlacement(scopedLease)

        backend.set("B")
        _ = await refreshSpaceProvider(provider, displays: [displayUUID])
        layout.displaysDidPublish(snapshot)
        XCTAssertEqual(layout.currentLayout.id, layoutB.id)
        XCTAssertEqual(layout.zones.count, 3, "Manual zones must be recalculated from Space B's selected layout.")
        layout.recordAppZoneHistory(key: AppZoneHistoryKey(bundleID: "com.example.Space", displayUUID: displayUUID,
                                                           spaceScope: .space(spaceB), layoutID: layoutB.id),
                                    expectedLayout: layoutB, zoneIDs: [1])
        let scopedLeaseB = layout.reserveAppPlacement(token: RuntimeWindowToken(id: UUID(), pid: 44),
                                                      bundleID: "com.example.Space", display: display,
                                                      layout: layoutB)
        XCTAssertEqual(scopedLeaseB?.key.spaceScope, .space(spaceB))
        layout.releaseAppPlacement(scopedLeaseB)
        let common = PersistedSpaceScope.common
        layout.spaceProvider.useCommonOnlyMode()
        _ = await refreshSpaceProvider(provider, displays: [displayUUID])
        layout.displaysDidPublish(snapshot)
        XCTAssertEqual(layout.spaceSnapshot(for: display).mode, .commonOnly)
        let commonLeaseInCommonMode = layout.reserveAppPlacement(token: RuntimeWindowToken(id: UUID(), pid: 43),
                                                                 bundleID: "com.example.Space", display: display,
                                                                 layout: layout.currentLayout)
        XCTAssertNotNil(commonLeaseInCommonMode, "commonOnly must preserve Issue #11 history reservation behavior.")
        XCTAssertEqual(commonLeaseInCommonMode?.key.spaceScope, .common)
        layout.releaseAppPlacement(commonLeaseInCommonMode)
        layout.recordAppZoneHistory(key: AppZoneHistoryKey(bundleID: "com.example.Space", displayUUID: displayUUID,
                                                           spaceScope: common, layoutID: layout.currentLayout.id),
                                    expectedLayout: layout.currentLayout, zoneIDs: [0])
        try await assertHistoryScopes([.space(spaceA), .space(spaceB), .common], layout: layout, store: store)

        provider.requestScopedMode()
        backend.set(nil)
        _ = await refreshSpaceProvider(provider, displays: [displayUUID])
        layout.displaysDidPublish(snapshot)
        let degraded = layout.spaceSnapshot(for: display)
        XCTAssertEqual(degraded.mode, .degradedScoped)
        XCTAssertFalse(degraded.recordsHistory)
        XCTAssertFalse(degraded.allowsAutomaticRestore)
        XCTAssertEqual(layout.currentLayout.id, defaultLayout.id, "Degraded scope retains the common basic layout.")
        let degradedLease = layout.reserveAppPlacement(token: RuntimeWindowToken(id: UUID(), pid: 45),
                                                        bundleID: "com.example.Space", display: display,
                                                        layout: layout.currentLayout)
        XCTAssertNil(degradedLease)
    }

    func testPersistentSpaceIDRejectsEmptyAndWhitespaceValuesDuringDecode() throws {
        let invalid = Data(#"{"backend":"fake","opaqueID":" "}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PersistentSpaceID.self, from: invalid))
    }

    @MainActor
    func testPublicSpaceObserverStartStopDoesNotMultiplySubscriptions() {
        let center = NotificationCenter()
        let provider = SpaceProvider(backend: FakeFailedSpaceBackend(), notificationCenter: center)
        let calls = LockedCallbackCount()
        provider.start { calls.increment() }
        provider.start { calls.increment() }
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(calls.value, 1)

        provider.stop()
        provider.stop()
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(calls.value, 1)
    }

    @MainActor
    func testDegradedEditsStayTemporaryAcrossUnrelatedSaveAndRecovery() async throws {
        let displayUUID = UUID()
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 11),
                              persistentID: PersistentDisplayID(uuid: displayUUID), sessionID: UUID(),
                              name: "Degraded", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 780), isPrimary: true,
                              backingScaleFactor: 1)
        let secondUUID = UUID()
        let second = Display(runtimeID: RuntimeDisplayID(rawValue: 12),
                             persistentID: PersistentDisplayID(uuid: secondUUID), sessionID: UUID(),
                             name: "Second", frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
                             workArea: CGRect(x: 1_000, y: 0, width: 1_000, height: 780), isPrimary: false,
                             backingScaleFactor: 1)
        let defaultLayout = PersistentStoreCoordinator.defaultLayout()
        let quickLayout = testLayout(name: "Quick", columns: 2)
        let unrelated = testLayout(name: "Unrelated", columns: 3)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStoreCoordinator(directory: directory)
        try await store.saveLayoutAndAssignments([defaultLayout, quickLayout, unrelated], [
            PersistedAssignment(displayUUID: displayUUID, spaceScope: .common, layoutID: defaultLayout.id)
        ])
        let provider = SpaceProvider.production(backend: FakeFailedSpaceBackend())
        _ = await refreshSpaceProvider(provider, displays: [displayUUID, secondUUID])
        let displaySnapshot = DisplaySnapshot(displays: [display, second], primaryFrame: display.frame)
        let controller = LayoutController(displayProvider: DisplayProvider(snapshot: displaySnapshot),
                                          spaceProvider: provider, storeCoordinator: store)
        await controller.loadPersistentState()
        controller.displaysDidPublish(displaySnapshot)
        XCTAssertEqual(controller.spaceSnapshot(for: display).mode, .degradedScoped)

        XCTAssertEqual(controller.applyQuickLayout(quickLayout.id, at: CGPoint(x: 10, y: 10))?.id, quickLayout.id)
        controller.zoneCount = 2
        let temporaryID = controller.currentLayout.id
        XCTAssertNil(controller.savedLayouts[temporaryID], "A degraded direct edit must not enter the durable catalog.")
        let identity = EditorOperationIdentity(token: UUID(), targetDisplay: display.id, revision: 1,
                                               targetScope: .common,
                                               configurationRevision: controller.placementValidity.revision.configuration)
        let saved = await controller.saveEditorLayout(unrelated, identity: identity, copyOnWrite: false)
        if case .failure(let message) = saved { XCTFail(message) }

        let persisted = try await store.load()
        XCTAssertEqual(persisted.assignments[PersistedAssignmentKey(displayUUID: displayUUID, spaceScope: .common)]?.layoutID,
                       defaultLayout.id, "Temporary degraded quick/direct edits must not leak into an unrelated save.")
        XCTAssertNil(persisted.layouts[temporaryID])

        let nonselectedKey = controller.overrideKey(for: second, scope: .common)
        controller.degradedLayoutOverrides[nonselectedKey] = quickLayout
        provider.useCommonOnlyMode()
        _ = await refreshSpaceProvider(provider, displays: [displayUUID, secondUUID])
        controller.displaysDidPublish(displaySnapshot)
        XCTAssertNil(controller.degradedLayoutOverrides[nonselectedKey],
                     "Recovery must clear temporary overrides for every display, including nonselected displays.")
        XCTAssertEqual(controller.currentLayout.id, defaultLayout.id,
                       "Recovery returns to the stored common assignment instead of the degraded temporary override.")
        let relaunched = LayoutController(displayProvider: DisplayProvider(snapshot: displaySnapshot),
                                          spaceProvider: provider, storeCoordinator: store)
        await relaunched.loadPersistentState()
        relaunched.displaysDidPublish(displaySnapshot)
        XCTAssertEqual(relaunched.currentLayout.id, defaultLayout.id)
    }

    @MainActor
    private func assertHistoryScopes(
        _ expected: Set<PersistedSpaceScope>,
        layout: LayoutController,
        store: PersistentStoreCoordinator
    ) async throws {
        let flushed = await layout.flush()
        XCTAssertTrue(flushed)
        let loaded = try await store.load()
        XCTAssertEqual(Set(loaded.appZoneHistory.keys.map(\.spaceScope)), expected)
    }
}

@MainActor
extension SpaceProviderTests {
    func testProductionBackendLoadsExistingPreviewAssignmentWithoutOptInArgument() async throws {
        let displayUUID = UUID()
        let candidateUUID = "5EA7DC96-5689-1D28-6AF8-DB244D30E11E"
        let record: [String: Any] = [
            "osMajor": 27,
            "build": "26A434",
            "displayUUID": displayUUID.uuidString.uppercased(),
            "rawSpaceID": "58",
            "kind": "user",
            "error": NSNull(),
            "adoption": false,
            "rawSpaceType": 0,
            "spaceUUIDCandidate": candidateUUID
        ]
        let payload = String(data: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
                             encoding: .utf8)!
        let runner = SpaceHelperProcessRunner(testExecutableURL: URL(fileURLWithPath: "/bin/sh"),
                                              testArgumentPrefix: ["-c", "printf '%s' '\(payload)'"])
        let backend = SkyLightReadOnlyBackend(runner: runner, previewRequested: false,
                                              hostIdentity: .supported, architecture: "arm64")
        let explicitPreview = SkyLightReadOnlyBackend(runner: runner, previewRequested: true,
                                                      hostIdentity: .supported, architecture: "arm64")
        XCTAssertEqual(backend.identifier, SkyLightReadOnlyBackend.scopedNamespace)
        XCTAssertEqual(explicitPreview.identifier, backend.identifier)

        let specialSpace = try XCTUnwrap(PersistentSpaceID(backend: backend.identifier, opaqueID: candidateUUID))
        let defaultLayout = PersistentStoreCoordinator.defaultLayout()
        let scopedLayout = testLayout(name: "Saved preview layout", columns: 2)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStoreCoordinator(directory: directory)
        try await store.saveLayoutAndAssignments([defaultLayout, scopedLayout], [
            PersistedAssignment(displayUUID: displayUUID, spaceScope: .common, layoutID: defaultLayout.id),
            PersistedAssignment(displayUUID: displayUUID, spaceScope: .space(specialSpace), layoutID: scopedLayout.id)
        ])

        let provider = SpaceProvider.production(backend: backend)
        let request = provider.makeRefreshRequest(displays: [displayUUID])
        let deadline = DispatchTime.now().uptimeNanoseconds &+ 1_000_000_000
        let candidate = await provider.readCandidate(for: request, deadline: deadline)
        XCTAssertEqual(candidate.snapshots[displayUUID]?.mode, .validatedScoped)
        XCTAssertEqual(candidate.snapshots[displayUUID]?.persistedScope, .space(specialSpace))
        XCTAssertTrue(provider.publish(candidate, for: request))

        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1),
                              persistentID: PersistentDisplayID(uuid: displayUUID), sessionID: UUID(),
                              name: "Test", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 780), isPrimary: true,
                              backingScaleFactor: 1)
        let snapshot = DisplaySnapshot(displays: [display], primaryFrame: display.frame)
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: snapshot), spaceProvider: provider,
                                      storeCoordinator: store)
        await layout.loadPersistentState()
        layout.displaysDidPublish(snapshot)
        XCTAssertEqual(layout.spaceSnapshot(for: display).persistedScope, .space(specialSpace))
        XCTAssertEqual(layout.currentLayout.id, scopedLayout.id,
                       "The ordinary factory must resolve an existing assignment in the stable preview namespace.")
    }
}

private final class LockedCallbackCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private struct FakeValidatedSpaceBackend: ReadOnlySpaceBackend {
    let identifier = "fake"
    let canAdoptStableIdentifiers = true

    func snapshot(for displayUUID: UUID) async throws -> ReadOnlySpaceValue? {
        ReadOnlySpaceValue(id: displayUUID.uuidString, kind: .regular)
    }
}

private struct FakeFailedSpaceBackend: ReadOnlySpaceBackend {
    let identifier = "fake-failed"
    let canAdoptStableIdentifiers = true

    func snapshot(for displayUUID: UUID) async throws -> ReadOnlySpaceValue? { nil }
}

private final class SwitchingSpaceBackend: ReadOnlySpaceBackend, @unchecked Sendable {
    let identifier = "fake"
    let canAdoptStableIdentifiers = true
    private let lock = NSLock()
    private var value: String? = "A"

    func set(_ value: String?) { lock.lock(); self.value = value; lock.unlock() }
    func snapshot(for displayUUID: UUID) async throws -> ReadOnlySpaceValue? {
        lock.withLock { value.map { ReadOnlySpaceValue(id: $0, kind: .regular) } }
    }
}

@MainActor
func refreshSpaceProvider(_ provider: SpaceProvider, displays: [UUID]) async -> [UUID: DisplaySpaceSnapshot] {
    let request = provider.makeRefreshRequest(displays: displays)
    let candidate = await provider.readCandidate(for: request)
    XCTAssertTrue(provider.publish(candidate, for: request))
    return provider.snapshots
}

private func testLayout(name: String, columns: Int) -> PersistedLayout {
    let id = UUID()
    let percentages = Array(repeating: 10_000 / columns, count: columns - 1) + [10_000 - (10_000 / columns * (columns - 1))]
    let grid = GridLayout(id: LayoutID(rawValue: id), rows: 1, columns: columns,
                         rowPercentages: [10_000], columnPercentages: percentages,
                         cellChildMap: [Array(0 ..< columns)])
    return PersistedLayout(id: id, definition: .grid(grid), spacing: 10, template: .columns,
                           zoneCount: columns, name: name)
}
