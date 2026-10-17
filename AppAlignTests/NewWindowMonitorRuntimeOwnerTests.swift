import XCTest

extension NewWindowMonitorTests {
@MainActor
    func testRuntimeDestroyObserverTransfersOwnerWithoutPersistingUntilNextPlacement() async throws {
        let fixture = try await RuntimeDestroyOwnerFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let owner = try await fixture.token(pid: 33201)
        let waiter = try await fixture.token(pid: 33202)
        let ownerController = try await fixture.place(owner, zoneID: 0,
                                                      frame: CGRect(x: 100, y: 100, width: 300, height: 200))
        _ = try await fixture.place(waiter, zoneID: 0,
                                    frame: CGRect(x: 500, y: 100, width: 300, height: 200))
        let initialFlush = await fixture.layout.flush()
        XCTAssertTrue(initialFlush)
        XCTAssertTrue(fixture.layout.appHistoryCoordinator.isAssigned(token: owner))
        XCTAssertTrue(fixture.layout.appHistoryCoordinator.isAssigned(token: waiter))
        let key = AppZoneHistoryKey(bundleID: "com.example.Owner", displayUUID: fixture.display.persistentID!.uuid,
                                    spaceScope: .common, layoutID: fixture.persistedLayout.id)
        let beforeDestroy = try await fixture.store.load()
        let revisionBeforeDestroy = try XCTUnwrap(beforeDestroy.appZoneHistory[key]?.revision)

        await fixture.runtime.notifyWindowDestroyedForTesting(owner)
        try await eventually {
            let ownerLeaseCount = await fixture.runtime.historyLeaseCount(for: owner)
            return !fixture.layout.appHistoryCoordinator.isAssigned(token: owner) &&
                fixture.layout.appHistoryCoordinator.isAssigned(token: waiter) && ownerLeaseCount == 0
        }
        let afterTransfer = try await fixture.store.load()
        XCTAssertEqual(afterTransfer.appZoneHistory[key]?.revision, revisionBeforeDestroy,
                       "Destroy-time owner transfer is runtime-only and does not rewrite persistent history.")

        _ = try await fixture.place(waiter, zoneID: 1,
                                    frame: CGRect(x: 100, y: 400, width: 300, height: 200))
        let nextFlush = await fixture.layout.flush()
        XCTAssertTrue(nextFlush)
        let afterNextPlacement = try await fixture.store.load()
        XCTAssertEqual(afterNextPlacement.appZoneHistory[key]?.zoneIDs, [1])
        XCTAssertEqual(afterNextPlacement.appZoneHistory[key]?.revision, revisionBeforeDestroy + 1)
        let waiterLeaseCount = await fixture.runtime.historyLeaseCount(for: waiter)
        XCTAssertEqual(waiterLeaseCount, 1)
        XCTAssertTrue(ownerController.canRestore, "Owner transfer and later placement must not consume the manual Restore state.")
    }

    @MainActor
    func testStopDuringRejectedSeenLeaseRetainCannotResurrectProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignSeenRejectStop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStoreCoordinator(directory: directory)
        try await store.saveLayouts([PersistentStoreCoordinator.defaultLayout()])
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [], primaryFrame: .zero)),
                                      storeCoordinator: store)
        await layout.loadPersistentState()
        var settings = layout.appHistorySettings
        settings.monitorNewWindows = true
        layout.appHistorySettings = settings
        let launchDate = Date(timeIntervalSince1970: 23)
        let application = MonitoredApplication(pid: 31994, bundleID: "com.example.SeenReject",
                                               launchDate: launchDate, isTerminated: false)
        let provider = MonitorProcessProvider(applications: [application])
        let runtime = MonitorRuntime()
        let generation = await runtime.generation(for: application.pid)
        let existing = RuntimeWindowToken(id: UUID(), pid: application.pid, processGeneration: generation)
        let candidate = RuntimeWindowToken(id: UUID(), pid: application.pid, processGeneration: generation)
        await runtime.setSnapshot([WindowObservationCandidate(token: existing, readiness: .ready(.zero))], pid: application.pid)
        let monitor = NewWindowMonitor(layout: layout, runtime: runtime, processProvider: provider, ownPID: -1)
        monitor.start()
        try await eventually { monitor.completedReconcileCount == 1 && monitor.observedWindowCount == 1 }

        await runtime.setSnapshot([
            WindowObservationCandidate(token: candidate, readiness: .temporarilyUnavailable),
            WindowObservationCandidate(token: existing, readiness: .ready(.zero))
        ], pid: application.pid)
        await runtime.pauseNextSeenRetention()
        monitor.receive(NewWindowSignal(kind: .created, pid: application.pid, generation: generation,
                                        launchDate: launchDate, bundleID: application.bundleID,
                                        duringBaseline: false, afterBaseline: true, epoch: 1))
        await runtime.waitForPausedSeenRetention()
        monitor.stop()
        await runtime.rejectNextSeenRetention()
        await runtime.releasePausedSeenRetention()
        await monitor.drainForShutdown()

        try await eventually { await runtime.completedSeenRetainCount() == 2 }
        XCTAssertEqual(monitor.observedProcessCount, 0)
        XCTAssertEqual(monitor.observedWindowCount, 0)
        let retainedSeenCount = await runtime.seenLeaseCount()
        XCTAssertEqual(retainedSeenCount, 0)
    }
}
