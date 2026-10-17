import AppKit
import XCTest

final class NewWindowMonitorTests: XCTestCase {
    func makeWritingTicket() -> PlacementCommitTicket {
        let now = DispatchTime.now().uptimeNanoseconds
        let ticket = PlacementCommitTicket(startDeadline: now + 1_000_000_000,
                                           totalDeadline: now + 3_000_000_000)
        XCTAssertTrue(ticket.beginWrite(now: now))
        return ticket
    }

    func pendingTicket() -> PlacementCommitTicket {
        let now = DispatchTime.now().uptimeNanoseconds
        return PlacementCommitTicket(startDeadline: now + 1_000_000_000,
                                     totalDeadline: now + 3_000_000_000)
    }

    @MainActor
    func testStoppedHistoryDestroyEpochRejectsLaterRuntimeNotifications() async throws {
        let runtime = AccessibilityWindowRuntime(focusedWindowValidator: { _ in },
                                                 accessibilityTrustedProvider: { true },
                                                 historyObserverProvider: { _, _, _, _ in true })
        let delivered = RuntimeDestroyEventRecorder()
        await runtime.setHistoryWindowDestroyedHandler { token, _ in
            delivered.record(token)
        }
        let element = AXUIElementCreateApplication(33303)
        let token = try await runtime.token(for: AXWindow(applicationElement: element, element: element, pid: 33303))
        let lease = RuntimeHistoryLeaseID()
        let retained = await runtime.retainHistoryLease(token, lease: lease)
        XCTAssertTrue(retained)
        let activeSinkCount = await runtime.historyDestroySinkCount
        XCTAssertEqual(activeSinkCount, 1)

        await runtime.applyHistoryDestroyState(enabled: true, revision: 10)
        await runtime.applyHistoryDestroyState(enabled: false, revision: 11)
        let retiredSinkCount = await runtime.historyDestroySinkCount
        XCTAssertEqual(retiredSinkCount, 0)
        await runtime.notifyWindowDestroyedForTesting(token)
        XCTAssertTrue(delivered.tokens.isEmpty, "A notification after lifecycle invalidation cannot call the retired sink.")
        await runtime.applyHistoryDestroyState(enabled: true, revision: 10)
        let staleResumeSinkCount = await runtime.historyDestroySinkCount
        XCTAssertEqual(staleResumeSinkCount, 0, "A delayed resume command cannot override a newer stop revision.")
        await runtime.applyHistoryDestroyState(enabled: true, revision: 12)
        try await eventually { delivered.tokens == [token] }
        await runtime.notifyWindowDestroyedForTesting(token)
        XCTAssertEqual(delivered.tokens, [token], "Re-registering a destroyed tracker emits one fresh cleanup event.")
        let retainedLeaseCount = await runtime.historyLeaseCount(for: token)
        XCTAssertEqual(retainedLeaseCount, 1,
                       "Stopping observation does not release an unrelated live history assignment.")

        await runtime.releaseHistoryLease(token, lease: lease)
        let cleanedSinkCount = await runtime.historyDestroySinkCount
        XCTAssertEqual(cleanedSinkCount, 0)
    }

    @MainActor
    func testCallbackFloodDuringPausedBaselineRunsOneDrainAndOneFreshBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignMonitorFlood-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStoreCoordinator(directory: directory)
        try await store.saveLayouts([PersistentStoreCoordinator.defaultLayout()])
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: nil, sessionID: UUID(),
                              name: "Monitor", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              isPrimary: true, backingScaleFactor: 1)
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)),
                                      storeCoordinator: store)
        await layout.loadPersistentState()
        let app = MonitoredApplication(pid: 32001, bundleID: "com.example.Flood", launchDate: Date(timeIntervalSince1970: 20), isTerminated: false)
        let provider = MonitorProcessProvider(applications: [app])
        let runtime = MonitorRuntime()
        let token = RuntimeWindowToken(id: UUID(), pid: app.pid, processGeneration: await runtime.generation(for: app.pid))
        await runtime.setSnapshot([WindowObservationCandidate(token: token, readiness: .temporarilyUnavailable)], pid: app.pid)
        await runtime.pauseNextSnapshot()
        let monitor = NewWindowMonitor(layout: layout, runtime: runtime, processProvider: provider, ownPID: -1)
        monitor.start()
        await runtime.waitForPausedSnapshot()

        for pid in pid_t(40_000) ..< pid_t(50_000) {
            monitor.receive(NewWindowSignal(kind: .created, pid: pid, generation: UUID(),
                                            launchDate: nil, bundleID: nil, duringBaseline: false,
                                            afterBaseline: true, epoch: 1))
        }
        await runtime.releasePausedSnapshot()
        try await eventually { await runtime.snapshotCount() == 2 && monitor.completedReconcileCount >= 2 }
        XCTAssertLessThanOrEqual(monitor.observedWindowCount, 64)
        let snapshotCount = await runtime.snapshotCount()
        XCTAssertEqual(snapshotCount, 2, "The burst causes one overflow epoch and one re-baseline, never one Task per signal.")
        XCTAssertEqual(monitor.diagnostics.filter { $0.contains("capacity was exceeded") }.count, 1)
        let freshSeenLeaseCount = await runtime.seenLeaseCount()
        XCTAssertEqual(freshSeenLeaseCount, 1,
                       "Overflow releases old epoch seen leases before the fresh baseline reacquires its window.")
        monitor.stop()
    }

    @MainActor
    func testStopWhileOverflowCleanupIsBlockedCannotReinstallOldObservers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignMonitorOverflowStop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStoreCoordinator(directory: directory)
        try await store.saveLayouts([PersistentStoreCoordinator.defaultLayout()])
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: nil, sessionID: UUID(),
                              name: "Monitor", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              isPrimary: true, backingScaleFactor: 1)
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)),
                                      storeCoordinator: store)
        await layout.loadPersistentState()
        let app = MonitoredApplication(pid: 32002, bundleID: "com.example.OverflowStop",
                                       launchDate: Date(timeIntervalSince1970: 21), isTerminated: false)
        let provider = MonitorProcessProvider(applications: [app])
        let runtime = MonitorRuntime()
        let token = RuntimeWindowToken(id: UUID(), pid: app.pid, processGeneration: await runtime.generation(for: app.pid))
        await runtime.setSnapshot([WindowObservationCandidate(token: token, readiness: .temporarilyUnavailable)], pid: app.pid)
        await runtime.pauseNextSnapshot()
        let monitor = NewWindowMonitor(layout: layout, runtime: runtime, processProvider: provider, ownPID: -1)
        monitor.start()
        await runtime.waitForPausedSnapshot()
        for pid in pid_t(50_000) ..< pid_t(50_200) {
            monitor.receive(NewWindowSignal(kind: .created, pid: pid, generation: UUID(), launchDate: nil,
                                            bundleID: nil, duringBaseline: false, afterBaseline: true, epoch: 1))
        }
        await runtime.pauseNextObservationStop()
        await runtime.releasePausedSnapshot()
        await runtime.waitForPausedObservationStop()
        monitor.stop()
        await runtime.releasePausedObservationStop()
        await monitor.drainForShutdown()
        XCTAssertEqual(monitor.observedProcessCount, 0)
        let observationCount = await runtime.observationCount()
        XCTAssertEqual(observationCount, 0,
                       "The old overflow restart cannot recreate its observer after stop advances the epoch.")
        let seenLeaseCount = await runtime.seenLeaseCount()
        XCTAssertEqual(seenLeaseCount, 0, "Overflow cleanup releases its exact old seen lease.")
        let registrationCount = await runtime.observationRegistrationCount()
        XCTAssertEqual(registrationCount, 1,
                       "No fresh observer is installed after a stop races with overflow cleanup.")
    }

    @MainActor
    func testStopDuringSeenLeaseRetainReleasesTheLateLease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignSeenStop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStoreCoordinator(directory: directory)
        try await store.saveLayouts([PersistentStoreCoordinator.defaultLayout()])
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [], primaryFrame: .zero)),
                                      storeCoordinator: store)
        await layout.loadPersistentState()
        var settings = layout.appHistorySettings
        settings.monitorNewWindows = true
        layout.appHistorySettings = settings
        let app = MonitoredApplication(pid: 31993, bundleID: "com.example.SeenStop", launchDate: Date(timeIntervalSince1970: 19), isTerminated: false)
        let provider = MonitorProcessProvider(applications: [app])
        let runtime = MonitorRuntime()
        let token = RuntimeWindowToken(id: UUID(), pid: app.pid, processGeneration: await runtime.generation(for: app.pid))
        await runtime.setSnapshot([WindowObservationCandidate(token: token, readiness: .terminal)], pid: app.pid)
        await runtime.pauseNextSeenRetention()
        let monitor = NewWindowMonitor(layout: layout, runtime: runtime, processProvider: provider, ownPID: -1)
        monitor.start()
        await runtime.waitForPausedSeenRetention()
        monitor.stop()
        await runtime.releasePausedSeenRetention()
        try await eventually {
            let completedRetains = await runtime.completedSeenRetainCount()
            let registeredLeaseRelease = await runtime.retainedAndReleasedSeenLeaseCount()
            return completedRetains == 1 && registeredLeaseRelease == 1
        }
        XCTAssertEqual(monitor.observedWindowCount, 0)
    }

    @MainActor
    func testRestoreOffCancelsOnlyAutomaticWorkAndMonitorOffStopsObservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignRestoreToggle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStoreCoordinator(directory: directory)
        try await store.saveLayouts([PersistentStoreCoordinator.defaultLayout()])
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: nil, sessionID: UUID(),
                              name: "Monitor", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              isPrimary: true, backingScaleFactor: 1)
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)),
                                      storeCoordinator: store)
        await layout.loadPersistentState()
        let app = MonitoredApplication(pid: 32101, bundleID: "com.example.RestoreToggle",
                                       launchDate: Date(timeIntervalSince1970: 30), isTerminated: false)
        let provider = MonitorProcessProvider(applications: [app])
        let runtime = MonitorRuntime()
        let monitor = NewWindowMonitor(layout: layout, runtime: runtime, processProvider: provider, ownPID: -1)
        var cancellationCount = 0
        var stopCount = 0
        monitor.onEnvironmentChanged = { cancellationCount += 1 }
        monitor.onStop = { stopCount += 1 }
        var settings = layout.appHistorySettings
        settings.monitorNewWindows = true
        settings.restoreNewWindows = true
        monitor.update(settings: settings, accessibilityAllowed: true)
        try await eventually { await runtime.snapshotCount() == 1 && monitor.observedProcessCount == 1 }

        settings.restoreNewWindows = false
        monitor.update(settings: settings, accessibilityAllowed: true)
        XCTAssertEqual(cancellationCount, 1, "Turning off automatic restore synchronously cancels its owned tickets.")
        XCTAssertEqual(stopCount, 0, "Monitoring remains active while only restore is disabled.")
        let generation = await runtime.generation(for: app.pid)
        let token = RuntimeWindowToken(id: UUID(), pid: app.pid, processGeneration: generation)
        await runtime.setSnapshot([WindowObservationCandidate(token: token,
                                                               readiness: .ready(CGRect(x: 30, y: 40, width: 200, height: 100)))],
                                  pid: app.pid)
        monitor.receive(NewWindowSignal(kind: .created, pid: app.pid, generation: generation,
                                        launchDate: nil, bundleID: nil, duringBaseline: false,
                                        afterBaseline: true, epoch: 1))
        try await eventually { await runtime.snapshotCount() == 2 && monitor.observedWindowCount == 1 }

        settings.monitorNewWindows = false
        monitor.update(settings: settings, accessibilityAllowed: true)
        XCTAssertEqual(stopCount, 1, "Turning monitoring off stops workspace and process observation.")
        XCTAssertEqual(monitor.observedProcessCount, 0)
    }

    @MainActor
    func eventually(_ predicate: () async -> Bool) async throws {
        for _ in 0 ..< 200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The asynchronous monitor operation did not complete.")
    }
}
