import XCTest

extension NewWindowMonitorTests {
    @MainActor
    func testAutomaticHistoryRetainPropagatesTwoHundredMillisecondDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignR25Deadline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStoreCoordinator(directory: directory)
        let persistedLayout = PersistentStoreCoordinator.defaultLayout()
        try await store.saveLayouts([persistedLayout])
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: PersistentDisplayID(uuid: UUID()),
                              sessionID: UUID(), name: "R25", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800), isPrimary: true, backingScaleFactor: 1)
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)),
                                      storeCoordinator: store)
        await layout.loadPersistentState()
        let probe = R25ObserverProbe(blockFirstCall: false)
        let runtime = AccessibilityWindowRuntime(focusedWindowValidator: { _ in },
                                                 accessibilityTrustedProvider: { true },
                                                 historyObserverProvider: { _, _, _, deadline in probe.register(deadline: deadline) })
        let pid: pid_t = 52321
        let launchDate = Date(timeIntervalSince1970: 53)
        _ = await runtime.processGenerationForMonitoring(pid, launchDate: launchDate)
        let element = AXUIElementCreateApplication(pid)
        let token = try await runtime.token(for: AXWindow(applicationElement: element, element: element, pid: pid))
        let lease = layout.reserveAppPlacement(token: token, bundleID: "com.example.R25", display: display,
                                               layout: persistedLayout)
        let callStartedAt = DispatchTime.now().uptimeNanoseconds
        let deadline = callStartedAt + 200_000_000
        let acquired = await layout.acquireAppPlacement(lease, using: runtime, retainDeadline: deadline)
        XCTAssertNotNil(acquired)
        let registeredDeadlines = probe.deadlines
        let observerDeadline = try XCTUnwrap(registeredDeadlines.first)
        XCTAssertGreaterThan(observerDeadline, callStartedAt)
        XCTAssertLessThanOrEqual(observerDeadline, deadline)
        XCTAssertLessThanOrEqual(observerDeadline - callStartedAt, 200_000_000)
        if let acquired { await runtime.releaseHistoryLease(acquired.token, lease: acquired.runtimeLeaseID) }

        let ordinaryElement = AXUIElementCreateApplication(62_321)
        let ordinaryToken = try await runtime.token(for: AXWindow(applicationElement: element,
                                                                  element: ordinaryElement, pid: pid))
        let ordinaryStartedAt = DispatchTime.now().uptimeNanoseconds
        let ordinaryLease = RuntimeHistoryLeaseID()
        let ordinaryRetained = await runtime.retainHistoryLease(ordinaryToken, lease: ordinaryLease)
        XCTAssertTrue(ordinaryRetained)
        let ordinaryDeadline = try XCTUnwrap(probe.deadlines.last)
        let ordinaryObserverStartedAt = try XCTUnwrap(probe.registrationTimes.last)
        XCTAssertGreaterThanOrEqual(ordinaryDeadline - ordinaryObserverStartedAt, 900_000_000)
        XCTAssertLessThanOrEqual(ordinaryDeadline - ordinaryObserverStartedAt, 1_000_000_000)
        XCTAssertGreaterThanOrEqual(ordinaryObserverStartedAt, ordinaryStartedAt)
        await runtime.releaseHistoryLease(ordinaryToken, lease: ordinaryLease)
    }

    @MainActor
    func testExpiredBoundedRetainQueuedBehindRuntimeWorkSkipsObserverAndPendingLease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignR25Expired-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStoreCoordinator(directory: directory)
        let persistedLayout = PersistentStoreCoordinator.defaultLayout()
        try await store.saveLayouts([persistedLayout])
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: PersistentDisplayID(uuid: UUID()),
                              sessionID: UUID(), name: "R25", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800), isPrimary: true, backingScaleFactor: 1)
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)),
                                      storeCoordinator: store)
        await layout.loadPersistentState()
        let probe = R25ObserverProbe(blockFirstCall: true)
        let runtime = AccessibilityWindowRuntime(focusedWindowValidator: { _ in },
                                                 accessibilityTrustedProvider: { true },
                                                 historyObserverProvider: { _, _, _, deadline in probe.register(deadline: deadline) })
        let pid: pid_t = 52322
        let launchDate = Date(timeIntervalSince1970: 54)
        _ = await runtime.processGenerationForMonitoring(pid, launchDate: launchDate)
        let applicationElement = AXUIElementCreateApplication(pid)
        let firstElement = AXUIElementCreateApplication(62_001)
        let secondElement = AXUIElementCreateApplication(62_002)
        let firstToken = try await runtime.token(for: AXWindow(applicationElement: applicationElement, element: firstElement, pid: pid))
        let secondToken = try await runtime.token(for: AXWindow(applicationElement: applicationElement, element: secondElement, pid: pid))
        let existingLease = RuntimeHistoryLeaseID()
        let firstRetain = Task { await runtime.retainHistoryLease(firstToken, lease: existingLease) }
        await probe.waitUntilFirstCallEntered()

        let pendingLease = layout.reserveAppPlacement(token: secondToken, bundleID: "com.example.R25", display: display,
                                                      layout: persistedLayout)
        let expiredDeadline = DispatchTime.now().uptimeNanoseconds + 50_000_000
        let queuedRetain = Task {
            await layout.acquireAppPlacement(pendingLease, using: runtime, retainDeadline: expiredDeadline)
        }
        try await Task.sleep(for: .milliseconds(120))
        probe.releaseFirstCall()
        let firstRetainSucceeded = await firstRetain.value
        let queuedLease = await queuedRetain.value
        XCTAssertTrue(firstRetainSucceeded)
        XCTAssertNil(queuedLease)
        XCTAssertEqual(probe.callCount, 1, "The actor checks the absolute deadline before calling the observer hook.")
        let firstLeaseCount = await runtime.historyLeaseCount(for: firstToken)
        let secondLeaseCount = await runtime.historyLeaseCount(for: secondToken)
        XCTAssertEqual(firstLeaseCount, 1, "An unrelated live history owner remains retained.")
        XCTAssertEqual(secondLeaseCount, 0)
        if let pendingLease { XCTAssertFalse(layout.appHistoryCoordinator.isPending(pendingLease)) }
        await runtime.releaseHistoryLease(firstToken, lease: existingLease)
    }

    @MainActor
    func testRuntimeCapacityCloseAndCreateSameSnapshotRescansOnce() async throws {
        let scenario = try await R23CapacityScenario.make()
        defer { try? FileManager.default.removeItem(at: scenario.directory) }
        try await scenario.assertInitialCapacity()
        try await scenario.assertSameCycleRescan()
        try await scenario.assertOneRetryWhenCapacityRemainsOwned()
        try await scenario.assertNextSnapshotAdmitsAfterRelease()
        await scenario.assertPartialSnapshotPreservesSeen()
        scenario.monitor.stop()
        await scenario.monitor.drainForShutdown()
    }

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

@MainActor
private final class R23CapacityScenario {
    let directory: URL
    let runtime: AccessibilityWindowRuntime
    let monitor: NewWindowMonitor
    let inventory: R23RawWindowInventory
    let pid: pid_t
    let generation: UUID
    let applicationElement: AXUIElement
    let windows: [AXWindow]
    let tokens: [RuntimeWindowToken]
    let blockedWindow: AXWindow
    private(set) var discovered: [RuntimeWindowToken] = []
    private(set) var closed: [RuntimeWindowToken] = []
    private(set) var newToken: RuntimeWindowToken?

    private init(directory: URL, runtime: AccessibilityWindowRuntime, monitor: NewWindowMonitor,
                 inventory: R23RawWindowInventory, pid: pid_t, generation: UUID,
                 applicationElement: AXUIElement, windows: [AXWindow], tokens: [RuntimeWindowToken],
                 blockedWindow: AXWindow) {
        self.directory = directory
        self.runtime = runtime
        self.monitor = monitor
        self.inventory = inventory
        self.pid = pid
        self.generation = generation
        self.applicationElement = applicationElement
        self.windows = windows
        self.tokens = tokens
        self.blockedWindow = blockedWindow
    }

    static func make() async throws -> R23CapacityScenario {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignR23Capacity-\(UUID().uuidString)")
        let store = PersistentStoreCoordinator(directory: directory)
        let persistedLayout = PersistentStoreCoordinator.defaultLayout()
        try await store.saveLayouts([persistedLayout])
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: PersistentDisplayID(uuid: UUID()),
                              sessionID: UUID(), name: "R23", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800), isPrimary: true, backingScaleFactor: 1)
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)),
                                      storeCoordinator: store)
        await layout.loadPersistentState()
        var settings = layout.appHistorySettings
        settings.monitorNewWindows = true
        settings.restoreNewWindows = true
        layout.appHistorySettings = settings
        let pid = pid_t(52301)
        let launchDate = Date(timeIntervalSince1970: 52)
        let application = MonitoredApplication(pid: pid, bundleID: "com.example.R23", launchDate: launchDate, isTerminated: false)
        let provider = MonitorProcessProvider(applications: [application])
        let inventory = R23RawWindowInventory()
        let runtime = AccessibilityWindowRuntime(focusedWindowValidator: { _ in },
                                                 accessibilityTrustedProvider: { true },
                                                 historyObserverProvider: { _, _, _, _ in true },
                                                 applicationWindowsProvider: { _, _, _ in inventory.read() },
                                                 observationFrameProvider: { _ in CGRect(x: 10, y: 20, width: 300, height: 200) })
        let generation = await runtime.processGenerationForMonitoring(pid, launchDate: launchDate)
        let applicationElement = AXUIElementCreateApplication(pid)
        let windows = (0 ..< 129).map { index in
            AXWindow(applicationElement: applicationElement, element: AXUIElementCreateApplication(pid_t(60_000 + index)), pid: pid)
        }
        XCTAssertFalse(CFEqual(windows[0].element, windows[1].element))
        var tokens: [RuntimeWindowToken] = []
        for window in windows.prefix(128) { tokens.append(try await runtime.token(for: window)) }
        for token in tokens.prefix(64) {
            let retained = await runtime.retainHistoryLease(token, lease: RuntimeHistoryLeaseID())
            XCTAssertTrue(retained)
        }
        inventory.set(Array(windows[64 ..< 128]))
        let monitor = NewWindowMonitor(layout: layout, runtime: runtime, processProvider: provider, ownPID: -1)
        let blockedWindow = AXWindow(applicationElement: applicationElement,
                                     element: AXUIElementCreateApplication(61_299), pid: pid)
        let scenario = R23CapacityScenario(directory: directory, runtime: runtime, monitor: monitor,
                                           inventory: inventory, pid: pid, generation: generation,
                                           applicationElement: applicationElement, windows: windows,
                                           tokens: tokens, blockedWindow: blockedWindow)
        monitor.onNewWindow = { [weak scenario] candidate, _ in scenario?.discovered.append(candidate.token) }
        monitor.onWindowClosed = { [weak scenario] token in scenario?.closed.append(token) }
        monitor.start()
        try await r23Eventually { monitor.completedReconcileCount == 1 && monitor.observedWindowCount == 64 }
        return scenario
    }

    func assertInitialCapacity() async throws {
        let baselineRecordCount = await runtime.records.count
        let baselineSeenTokenCount = await runtime.retainedMonitorSeenTokenCount
        XCTAssertEqual(baselineRecordCount, 128)
        XCTAssertEqual(tokens.prefix(64).count, 64)
        XCTAssertEqual(baselineSeenTokenCount, 64)
        inventory.resetReadCount()
        inventory.set(Array(windows[65 ..< 128]) + [windows[128]])
        let preflight = try await runtime.observedWindows(applicationPID: pid, processGeneration: generation,
                                                          ownPID: -1, deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
        XCTAssertTrue(preflight.isComplete)
        XCTAssertTrue(preflight.hasUntrackedWindowsDueToCapacity,
                      "A complete AX inventory reports capacity loss distinctly from a partial snapshot.")
        XCTAssertEqual(inventory.readCount, 1)
        let fullRecordCount = await runtime.records.count
        XCTAssertEqual(fullRecordCount, 128)
    }

    func assertSameCycleRescan() async throws {
        inventory.resetReadCount()
        signal()
        try await r23Eventually { monitor.completedReconcileCount == 2 && discovered.count == 1 }
        XCTAssertEqual(inventory.readCount, 2, "The closed seen lease frees capacity for one same-cycle rescan.")
        newToken = try await runtime.token(for: windows[128])
        XCTAssertEqual(discovered, [newToken])
        XCTAssertEqual(closed, [tokens[64]])
        let finalSeenTokenCount = await runtime.retainedMonitorSeenTokenCount
        let finalRecordCount = await runtime.records.count
        XCTAssertEqual(finalSeenTokenCount, 64)
        XCTAssertLessThanOrEqual(finalRecordCount, 128)
        for token in tokens.prefix(64) {
            let leaseCount = await runtime.historyLeaseCount(for: token)
            XCTAssertEqual(leaseCount, 1)
        }
        signal()
        try await r23Eventually { monitor.completedReconcileCount == 3 }
        XCTAssertEqual(discovered, [newToken], "A token admitted by the rescan is not reclassified on the next snapshot.")
    }

    func assertOneRetryWhenCapacityRemainsOwned() async throws {
        let externalSeenLease = RuntimeMonitorSeenLeaseID()
        let retainedClosedToken = tokens[65]
        let externalRetained = await runtime.retainMonitorSeenLease(retainedClosedToken, lease: externalSeenLease)
        XCTAssertTrue(externalRetained)
        inventory.resetReadCount()
        inventory.set(Array(windows[66 ..< 128]) + [windows[128], blockedWindow])
        signal()
        try await r23Eventually { monitor.completedReconcileCount == 4 }
        XCTAssertEqual(inventory.readCount, 2, "Capacity loss triggers at most one retry even when another owner keeps the closed record alive.")
        XCTAssertEqual(monitor.observedWindowCount, 63)
        XCTAssertEqual(discovered, [newToken], "A still-owned closed record does not cause an unbounded retry or false admission.")
        XCTAssertEqual(closed, [tokens[64], retainedClosedToken])
        let heldSeenCount = await runtime.monitorSeenLeaseCount(for: retainedClosedToken)
        XCTAssertEqual(heldSeenCount, 1)
        await runtime.releaseMonitorSeenLease(retainedClosedToken, lease: externalSeenLease)
    }

    func assertNextSnapshotAdmitsAfterRelease() async throws {
        inventory.resetReadCount()
        signal()
        try await r23Eventually { monitor.completedReconcileCount == 5 && discovered.count == 2 }
        XCTAssertEqual(inventory.readCount, 1, "When no capacity miss remains, the next ordinary snapshot needs no extra pass.")
        let nextNewToken = try await runtime.token(for: blockedWindow)
        XCTAssertEqual(discovered, [newToken, nextNewToken])
    }

    func assertPartialSnapshotPreservesSeen() async {
        let partialA = AXWindow(applicationElement: applicationElement,
                                element: AXUIElementCreateApplication(61_300), pid: pid)
        let partialB = AXWindow(applicationElement: applicationElement,
                                element: AXUIElementCreateApplication(61_301), pid: pid)
        inventory.set(Array(windows[67 ..< 128]) + [windows[128], blockedWindow, partialA, partialB])
        inventory.resetReadCount()
        signal()
        await monitor.waitForCurrentDrain()
        XCTAssertEqual(inventory.readCount, 1)
        XCTAssertEqual(monitor.completedReconcileCount, 5, "A partial snapshot is processed but does not complete a baseline/reconcile pass.")
        XCTAssertEqual(monitor.observedWindowCount, 64)
        XCTAssertEqual(closed, [tokens[64], tokens[65]], "An incomplete raw inventory never closes missing identities.")
    }

    private func signal() {
        monitor.receive(NewWindowSignal(kind: .created, pid: pid, generation: generation, launchDate: nil,
                                        bundleID: nil, duringBaseline: false, afterBaseline: true, epoch: 1))
    }
}

@MainActor
private func r23Eventually(_ predicate: () async -> Bool) async throws {
    for _ in 0 ..< 200 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("The asynchronous R23 scenario did not complete.")
}

private final class R23RawWindowInventory: @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [AXWindow] = []
    private var reads = 0

    func set(_ windows: [AXWindow]) { lock.withLock { self.windows = windows } }
    func read() -> [AXWindow] { lock.withLock { reads += 1; return windows } }
    func resetReadCount() { lock.withLock { reads = 0 } }
    var readCount: Int { lock.withLock { reads } }
}

private final class R25ObserverProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let blockFirstCall: Bool
    private let entered = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)
    private var calls = 0
    private var observedDeadlines: [UInt64] = []
    private var observedRegistrationTimes: [UInt64] = []

    init(blockFirstCall: Bool) { self.blockFirstCall = blockFirstCall }

    func register(deadline: UInt64) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldBlock = lock.withLock { () -> Bool in
            calls += 1
            observedDeadlines.append(deadline)
            observedRegistrationTimes.append(now)
            return blockFirstCall && calls == 1
        }
        if shouldBlock {
            entered.signal()
            releaseGate.wait()
        }
        return true
    }

    func waitUntilFirstCallEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.entered.wait()
                continuation.resume()
            }
        }
    }

    func releaseFirstCall() { releaseGate.signal() }
    var callCount: Int { lock.withLock { calls } }
    var deadlines: [UInt64] { lock.withLock { observedDeadlines } }
    var registrationTimes: [UInt64] { lock.withLock { observedRegistrationTimes } }
}
