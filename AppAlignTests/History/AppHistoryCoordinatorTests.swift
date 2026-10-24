import XCTest

@MainActor
final class AppHistoryCoordinatorTests: XCTestCase {
    @MainActor
    func testPendingHistoryLeaseDestroyedDuringRetainReleasesOnlyItsRuntimeLease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignHistoryRetainRace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PersistentStoreCoordinator(directory: directory)
        let layout = PersistentStoreCoordinator.defaultLayout()
        try await store.saveLayouts([layout])
        let displayID = UUID()
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1),
                              persistentID: PersistentDisplayID(uuid: displayID), sessionID: UUID(),
                              name: "Race display", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 780),
                              isPrimary: true, backingScaleFactor: 1)
        let displayProvider = DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame))
        let controller = LayoutController(displayProvider: displayProvider, storeCoordinator: store)
        await controller.loadPersistentState()
        XCTAssertTrue(controller.appZoneHistoryAvailable)

        let runtime = HistoryLeaseBarrierRuntime()
        let generation = UUID()
        let owner = RuntimeWindowToken(id: UUID(), pid: 310, processGeneration: generation)
        let racingToken = RuntimeWindowToken(id: UUID(), pid: 310, processGeneration: generation)
        let ownerLease = try XCTUnwrap(controller.reserveAppPlacement(token: owner, bundleID: "com.example.Race",
                                                                       display: display, layout: layout))
        let acquiredOwner = await controller.acquireAppPlacement(ownerLease, using: runtime)
        controller.acceptSuccessfulAppPlacement(acquiredOwner, zoneIDs: [0])
        let ownerFlushSucceeded = await controller.flush()
        XCTAssertTrue(ownerFlushSucceeded)

        let pending = try XCTUnwrap(controller.reserveAppPlacement(token: racingToken, bundleID: "com.example.Race",
                                                                    display: display, layout: layout))
        await runtime.blockNextRetain(for: racingToken)
        let acquisition = Task { @MainActor in await controller.acquireAppPlacement(pending, using: runtime) }
        await runtime.waitForBlockedRetain()
        controller.appWindowDestroyed(racingToken)
        await runtime.completeBlockedRetainSuccessfully()
        let racedResult = await acquisition.value
        XCTAssertNil(racedResult, "The invalidated pending lease cannot be returned as usable after its runtime retain completes.")
        let heldLeaseCount = await runtime.retainedLeaseCount()
        XCTAssertEqual(heldLeaseCount, 1, "The surviving owner lease must stay retained while the raced lease is released.")
        let releasedLeases = await runtime.releasedLeases()
        XCTAssertEqual(releasedLeases, [pending.runtimeLeaseID], "Only the lease acquired by the stale retain call is released.")

        let raceFlushSucceeded = await controller.flush()
        XCTAssertTrue(raceFlushSucceeded)
        let persisted = try await store.load()
        let key = AppZoneHistoryKey(bundleID: "com.example.Race", displayUUID: displayID,
                                    spaceScope: .common, layoutID: layout.id)
        XCTAssertEqual(persisted.appZoneHistory[key]?.zoneIDs, [0])
        XCTAssertEqual(persisted.appZoneHistory[key]?.revision, 1, "The destroyed token must not commit another history delta.")
    }

    func testOwnerMovesOnlyAfterSuccessAndTransfersWhenOwnerChangesLayout() throws {
        let coordinator = AppHistoryCoordinator()
        let displayID = UUID()
        let original = PersistentStoreCoordinator.defaultLayout()
        let moved = try makeLayout(id: UUID(), basedOn: original)
        let generation = UUID()
        let first = RuntimeWindowToken(id: UUID(), pid: 77, processGeneration: generation)
        let second = RuntimeWindowToken(id: UUID(), pid: 77, processGeneration: generation)

        let firstOwnerLease = try XCTUnwrap(coordinator.reservePlacement(token: first, bundleID: "com.example.App",
                                                                         displayUUID: displayID, expectedLayout: original))
        XCTAssertEqual(coordinator.acceptSuccessfulPlacement(firstOwnerLease), true)
        let secondLease = try XCTUnwrap(coordinator.reservePlacement(token: second, bundleID: "com.example.App",
                                                                      displayUUID: displayID, expectedLayout: original))
        XCTAssertEqual(coordinator.acceptSuccessfulPlacement(secondLease), false)

        let cancelledMove = try XCTUnwrap(coordinator.reservePlacement(token: first, bundleID: "com.example.App",
                                                                        displayUUID: displayID, expectedLayout: moved))
        XCTAssertTrue(coordinator.release(cancelledMove))
        let originalOwnerStillHolds = try XCTUnwrap(coordinator.reservePlacement(token: first, bundleID: "com.example.App",
                                                                                  displayUUID: displayID, expectedLayout: original))
        XCTAssertEqual(coordinator.acceptSuccessfulPlacement(originalOwnerStillHolds), true)

        let moveLease = try XCTUnwrap(coordinator.reservePlacement(token: first, bundleID: "com.example.App",
                                                                    displayUUID: displayID, expectedLayout: moved))
        XCTAssertEqual(coordinator.acceptSuccessfulPlacement(moveLease), true)
        let transferredOwnerLease = try XCTUnwrap(coordinator.reservePlacement(token: second, bundleID: "com.example.App",
                                                                                displayUUID: displayID, expectedLayout: original))
        XCTAssertEqual(coordinator.acceptSuccessfulPlacement(transferredOwnerLease), true)
    }

    func testSameTokenRepeatedKeysKeepsOneCurrentAssignment() throws {
        let coordinator = AppHistoryCoordinator()
        let token = RuntimeWindowToken(id: UUID(), pid: 88, processGeneration: UUID())
        let displayID = UUID()
        let base = PersistentStoreCoordinator.defaultLayout()
        for _ in 0 ..< 70 {
            let layout = try makeLayout(id: UUID(), basedOn: base)
            let lease = try XCTUnwrap(coordinator.reservePlacement(token: token, bundleID: "com.example.App",
                                                                  displayUUID: displayID, expectedLayout: layout))
            XCTAssertEqual(coordinator.acceptSuccessfulPlacement(lease), true)
        }
        let latest = try makeLayout(id: UUID(), basedOn: base)
        let pending = try XCTUnwrap(coordinator.reservePlacement(token: token, bundleID: "com.example.App",
                                                                 displayUUID: displayID, expectedLayout: latest))
        coordinator.restoreSucceeded(token)
        XCTAssertNil(coordinator.acceptSuccessfulPlacement(pending), "Restore must invalidate pending assignment leases.")
    }

    func testCurrentAssignmentsAreBoundedByUniqueTokensAcrossLayoutSwitches() throws {
        let coordinator = AppHistoryCoordinator()
        let displayID = UUID()
        let base = PersistentStoreCoordinator.defaultLayout()
        let tokens = (0 ..< 64).map { RuntimeWindowToken(id: UUID(), pid: pid_t(50_000 + $0), processGeneration: UUID()) }
        for (index, token) in tokens.enumerated() {
            let lease = try XCTUnwrap(coordinator.reservePlacement(token: token, bundleID: "com.example.Bounded",
                                                                  displayUUID: displayID, expectedLayout: base))
            XCTAssertEqual(coordinator.acceptSuccessfulPlacement(lease), index == 0,
                           "Only the oldest live token owns a shared history key.")
        }
        XCTAssertEqual(coordinator.assignedTokenCount, 64)
        let overflow = RuntimeWindowToken(id: UUID(), pid: 50_064, processGeneration: UUID())
        XCTAssertNil(coordinator.reservePlacement(token: overflow, bundleID: "com.example.Bounded",
                                                   displayUUID: displayID, expectedLayout: base))

        let switchingToken = tokens[0]
        for _ in 0 ..< 65 {
            let layout = try makeLayout(id: UUID(), basedOn: base)
            let lease = try XCTUnwrap(coordinator.reservePlacement(token: switchingToken, bundleID: "com.example.Bounded",
                                                                  displayUUID: displayID, expectedLayout: layout))
            XCTAssertEqual(coordinator.acceptSuccessfulPlacement(lease), true)
            XCTAssertEqual(coordinator.assignedTokenCount, 64,
                           "Moving one token between history keys replaces its current assignment instead of consuming capacity.")
        }
    }

    private func makeLayout(id: UUID, basedOn layout: PersistedLayout) throws -> PersistedLayout {
        PersistedLayout(id: id, definition: try layout.definition(), spacing: layout.spacing,
                        template: LayoutTemplate(rawValue: layout.template) ?? .grid,
                        zoneCount: layout.zoneCount, name: layout.name)
    }
}

private actor HistoryLeaseBarrierRuntime: WindowHistoryLeaseOperating {
    private var held = Set<RuntimeHistoryLeaseID>()
    private var released: [RuntimeHistoryLeaseID] = []
    private var blockedToken: RuntimeWindowToken?
    private var blockedRetain: CheckedContinuation<Bool, Never>?
    private var retainStarted: CheckedContinuation<Void, Never>?

    func blockNextRetain(for token: RuntimeWindowToken) { blockedToken = token }

    func retainHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID) async -> Bool {
        if token == blockedToken {
            blockedToken = nil
            let shouldRetain = await withCheckedContinuation { continuation in
                blockedRetain = continuation
                retainStarted?.resume()
                retainStarted = nil
            }
            if shouldRetain { held.insert(lease) }
            return shouldRetain
        }
        held.insert(lease)
        return true
    }

    func waitForBlockedRetain() async {
        if blockedRetain != nil { return }
        await withCheckedContinuation { retainStarted = $0 }
    }

    func completeBlockedRetainSuccessfully() {
        blockedRetain?.resume(returning: true)
        blockedRetain = nil
    }

    func releaseHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID) async {
        held.remove(lease)
        released.append(lease)
    }

    func retainedLeaseCount() -> Int { held.count }
    func releasedLeases() -> [RuntimeHistoryLeaseID] { released }
}
