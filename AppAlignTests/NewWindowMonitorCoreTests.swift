import XCTest

extension NewWindowMonitorTests {
@MainActor
    func testStartupUnreadyWindowIsSeenAndNewLaunchInitialWindowCanRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignMonitor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStoreCoordinator(directory: directory)
        let layout = PersistentStoreCoordinator.defaultLayout()
        try await store.saveLayouts([layout])
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1),
                              persistentID: PersistentDisplayID(uuid: UUID()), sessionID: UUID(),
                              name: "Monitor", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              isPrimary: true, backingScaleFactor: 1)
        let layoutController = LayoutController(
            displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)),
            storeCoordinator: store
        )
        await layoutController.loadPersistentState()
        var historySettings = layoutController.appHistorySettings
        historySettings.monitorNewWindows = true
        historySettings.restoreNewWindows = true
        layoutController.updateAppHistorySettings(historySettings)

        let oldApp = MonitoredApplication(pid: 31001, bundleID: "com.example.Existing", launchDate: Date(timeIntervalSince1970: 10), isTerminated: false)
        let provider = MonitorProcessProvider(applications: [oldApp])
        let runtime = MonitorRuntime()
        let oldGeneration = await runtime.generation(for: oldApp.pid)
        let oldToken = RuntimeWindowToken(id: UUID(), pid: oldApp.pid, processGeneration: oldGeneration)
        await runtime.setSnapshot([WindowObservationCandidate(token: oldToken, readiness: .temporarilyUnavailable)], pid: oldApp.pid)

        let monitor = NewWindowMonitor(layout: layoutController, runtime: runtime, processProvider: provider, ownPID: -1)
        var restoredTokens: [RuntimeWindowToken] = []
        monitor.onNewWindow = { candidate, _ in restoredTokens.append(candidate.token) }
        monitor.start()
        try await eventually { await runtime.observationCount() == 1 && monitor.observedWindowCount == 1 }

        await runtime.setSnapshot([WindowObservationCandidate(token: oldToken, readiness: .ready(CGRect(x: 0, y: 0, width: 200, height: 100)))], pid: oldApp.pid)
        monitor.receive(NewWindowSignal(kind: .created, pid: oldApp.pid, generation: oldGeneration,
                                        launchDate: nil, bundleID: nil, duringBaseline: false,
                                        afterBaseline: true, epoch: 1))
        try await eventually { await runtime.snapshotCount() == 2 }
        XCTAssertTrue(restoredTokens.isEmpty, "An identity seen during startup baseline must not become a restore candidate when its AX frame becomes ready.")

        let newApp = MonitoredApplication(pid: 31002, bundleID: "com.example.New", launchDate: Date().addingTimeInterval(1), isTerminated: false)
        provider.set(newApp)
        let newGeneration = await runtime.generation(for: newApp.pid)
        let newToken = RuntimeWindowToken(id: UUID(), pid: newApp.pid, processGeneration: newGeneration)
        await runtime.setSnapshot([WindowObservationCandidate(token: newToken, readiness: .ready(CGRect(x: 0, y: 0, width: 200, height: 100)))], pid: newApp.pid)
        monitor.receive(NewWindowSignal(kind: .launch, pid: newApp.pid, generation: nil,
                                        launchDate: newApp.launchDate, bundleID: newApp.bundleID,
                                        duringBaseline: false, afterBaseline: true, epoch: 1))
        try await eventually { restoredTokens == [newToken] }
        XCTAssertEqual(monitor.observedWindowCount, 2)
        monitor.stop()
    }
@MainActor
    func testStaleTerminationCannotDiscardNewProcessGenerationForReusedPID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignPIDReuse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStoreCoordinator(directory: directory)
        try await store.saveLayouts([PersistentStoreCoordinator.defaultLayout()])
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [], primaryFrame: .zero)),
                                      storeCoordinator: store)
        await layout.loadPersistentState()
        let pid: pid_t = 31999
        let originalDate = Date(timeIntervalSince1970: 30)
        let originalApp = MonitoredApplication(pid: pid, bundleID: "com.example.Reused", launchDate: originalDate, isTerminated: false)
        let provider = MonitorProcessProvider(applications: [originalApp])
        let runtime = MonitorRuntime()
        let originalGeneration = await runtime.generation(for: pid)
        let originalToken = RuntimeWindowToken(id: UUID(), pid: pid, processGeneration: originalGeneration)
        await runtime.setSnapshot([WindowObservationCandidate(token: originalToken, readiness: .ready(.zero))], pid: pid)
        let monitor = NewWindowMonitor(layout: layout, runtime: runtime, processProvider: provider, ownPID: -1)
        var terminatedGenerations: [UUID] = []
        monitor.onProcessTerminating = { _, generation in terminatedGenerations.append(generation) }
        monitor.start()
        try await eventually { await runtime.snapshotCount() == 1 }

        let replacement = MonitoredApplication(pid: pid, bundleID: originalApp.bundleID,
                                               launchDate: Date().addingTimeInterval(1), isTerminated: false)
        provider.set(replacement)
        let replacementToken = RuntimeWindowToken(id: UUID(), pid: pid, processGeneration: originalGeneration)
        await runtime.setSnapshot([WindowObservationCandidate(token: replacementToken, readiness: .ready(.zero))], pid: pid)
        monitor.receive(NewWindowSignal(kind: .launch, pid: pid, generation: nil, launchDate: replacement.launchDate,
                                        bundleID: replacement.bundleID, duringBaseline: false,
                                        afterBaseline: true, epoch: 1))
        try await eventually { await runtime.snapshotCount() == 2 && terminatedGenerations == [originalGeneration] }
        let replacementState = monitor.observedWindowCount
        monitor.receive(NewWindowSignal(kind: .terminate, pid: pid, generation: nil, launchDate: originalDate,
                                        bundleID: originalApp.bundleID, duringBaseline: false,
                                        afterBaseline: true, epoch: 1))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(monitor.observedProcessCount, 1)
        XCTAssertEqual(monitor.observedWindowCount, replacementState)
        monitor.stop()
    }
@MainActor
    func testQueuedCreationDuringBaselineNeverBecomesRestoreCandidate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignBaselineProvenance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStoreCoordinator(directory: directory)
        try await store.saveLayouts([PersistentStoreCoordinator.defaultLayout()])
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [], primaryFrame: .zero)),
                                      storeCoordinator: store)
        await layout.loadPersistentState()
        var settings = layout.appHistorySettings
        settings.monitorNewWindows = true
        settings.restoreNewWindows = true
        layout.appHistorySettings = settings
        let app = MonitoredApplication(pid: 31990, bundleID: "com.example.Baseline", launchDate: Date(timeIntervalSince1970: 15), isTerminated: false)
        let provider = MonitorProcessProvider(applications: [app])
        let runtime = MonitorRuntime()
        let token = RuntimeWindowToken(id: UUID(), pid: app.pid, processGeneration: await runtime.generation(for: app.pid))
        await runtime.setSnapshot([WindowObservationCandidate(token: token, readiness: .terminal)], pid: app.pid)
        await runtime.pauseNextSnapshot()
        let monitor = NewWindowMonitor(layout: layout, runtime: runtime, processProvider: provider, ownPID: -1)
        var candidates: [RuntimeWindowToken] = []
        monitor.onNewWindow = { candidate, _ in candidates.append(candidate.token) }
        monitor.start()
        await runtime.waitForPausedSnapshot()
        await runtime.setSnapshot([WindowObservationCandidate(token: token, readiness: .ready(CGRect(x: 1, y: 2, width: 200, height: 100)))], pid: app.pid)
        await runtime.emitCreation(pid: app.pid)
        await runtime.releasePausedSnapshot()
        try await eventually { await runtime.snapshotCount() == 2 }
        XCTAssertTrue(candidates.isEmpty, "A creation callback accepted while the startup baseline is active remains baseline provenance when drained later.")
        monitor.stop()
    }
@MainActor
    func testSeenWindowCapReleasesClosedIdentitiesAndTerminationCleansObserver() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignSeenCap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStoreCoordinator(directory: directory)
        try await store.saveLayouts([PersistentStoreCoordinator.defaultLayout()])
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [], primaryFrame: .zero)),
                                      storeCoordinator: store)
        await layout.loadPersistentState()
        var settings = layout.appHistorySettings
        settings.monitorNewWindows = true
        settings.restoreNewWindows = true
        layout.appHistorySettings = settings
        let app = MonitoredApplication(pid: 31991, bundleID: "com.example.Cap", launchDate: Date(timeIntervalSince1970: 16), isTerminated: false)
        let provider = MonitorProcessProvider(applications: [app])
        let runtime = MonitorRuntime()
        let generation = await runtime.generation(for: app.pid)
        let initialTokens = (0 ..< 65).map { _ in RuntimeWindowToken(id: UUID(), pid: app.pid, processGeneration: generation) }
        func candidates(_ tokens: [RuntimeWindowToken]) -> [WindowObservationCandidate] {
            tokens.map { WindowObservationCandidate(token: $0, readiness: .ready(.zero)) }
        }
        await runtime.setSnapshot(candidates(initialTokens), pid: app.pid)
        let monitor = NewWindowMonitor(layout: layout, runtime: runtime, processProvider: provider, ownPID: -1)
        var closed: [RuntimeWindowToken] = []
        var discovered: [RuntimeWindowToken] = []
        monitor.onWindowClosed = { closed.append($0) }
        monitor.onNewWindow = { candidate, _ in discovered.append(candidate.token) }
        monitor.start()
        try await eventually { monitor.observedWindowCount == 64 && monitor.completedReconcileCount == 1 }
        XCTAssertEqual(monitor.observedWindowCount, 64)

        let replacements = Array(initialTokens[1 ..< 64]) + [initialTokens[64]]
        await runtime.setSnapshot(candidates(replacements), pid: app.pid)
        monitor.receive(NewWindowSignal(kind: .created, pid: app.pid, generation: generation, launchDate: nil,
                                        bundleID: nil, duringBaseline: false, afterBaseline: true, epoch: 1))
        try await eventually { monitor.observedWindowCount == 64 && closed.count == 1 && discovered == [initialTokens[64]] }
        XCTAssertEqual(monitor.observedWindowCount, 64, "Closed identities release their seen lease before same-snapshot candidates use the slot.")
        XCTAssertEqual(closed, [initialTokens[0]])
        XCTAssertEqual(discovered, [initialTokens[64]])
        let completedReconciles = monitor.completedReconcileCount
        monitor.receive(NewWindowSignal(kind: .created, pid: app.pid, generation: generation, launchDate: nil,
                                        bundleID: nil, duringBaseline: false, afterBaseline: true, epoch: 1))
        try await eventually { monitor.completedReconcileCount == completedReconciles + 1 }
        XCTAssertEqual(discovered, [initialTokens[64]], "A retained identity is never reclassified as new on the next complete snapshot.")

        monitor.receive(NewWindowSignal(kind: .terminate, pid: app.pid, generation: nil, launchDate: app.launchDate,
                                        bundleID: app.bundleID, duringBaseline: false, afterBaseline: true, epoch: 1))
        try await eventually {
            let observationCount = await runtime.observationCount()
            return monitor.observedProcessCount == 0 && observationCount == 0
        }
        XCTAssertEqual(monitor.observedWindowCount, 0)
        monitor.stop()
    }
                    func testDedicatedAutomaticMoverDoesNotRetrySetterWhileOrdinaryMoverRetriesOnce() throws {
        let pid: pid_t = 33003
        let element = AXUIElementCreateApplication(pid)
        let window = AXWindow(applicationElement: element, element: element, pid: pid)
        let frame = CGRect(x: 30, y: 40, width: 500, height: 300)
        let automaticEffects = RetryProbePlacementEffects(failFirstPosition: true)
        let automaticMover = WindowMover(messagingTimeout: 0.2, retryLimit: 0, effects: automaticEffects)
        let automaticTicket = makeWritingTicket()
        XCTAssertEqual(automaticMover.messagingTimeout, 0.2)
        XCTAssertEqual(automaticMover.retryLimit, 0)
        XCTAssertThrowsError(try automaticMover.movePlacement(window, to: frame, ticket: automaticTicket))
        XCTAssertEqual(automaticEffects.positionAttempts, 1,
                       "Automatic placement must stop after the first retryable AX setter failure.")

        let ordinaryEffects = RetryProbePlacementEffects(failFirstPosition: true)
        let ordinaryMover = WindowMover(effects: ordinaryEffects)
        let ordinaryTicket = makeWritingTicket()
        XCTAssertEqual(ordinaryMover.messagingTimeout, 0.5)
        XCTAssertEqual(ordinaryMover.retryLimit, 1)
        let result = try ordinaryMover.movePlacement(window, to: frame, ticket: ordinaryTicket)
        XCTAssertEqual(result.actualFrame, frame)
        XCTAssertEqual(ordinaryEffects.positionAttempts, 3,
                       "The ordinary placement contract retries one failed attempt, then performs its usual two position writes.")
    }
@MainActor
    func testTemporaryReadinessUsesFiveAbsoluteRetryOffsetsDespiteAXTime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignAutoClock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStoreCoordinator(directory: directory)
        let persistedLayout = PersistentStoreCoordinator.defaultLayout()
        try await store.saveLayouts([persistedLayout])
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: PersistentDisplayID(uuid: UUID()),
                              sessionID: UUID(), name: "Clock", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800), isPrimary: true, backingScaleFactor: 1)
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)),
                                      storeCoordinator: store)
        await layout.loadPersistentState()
        var settings = layout.appHistorySettings
        settings.monitorNewWindows = true
        settings.restoreNewWindows = true
        layout.appHistorySettings = settings
        let key = AppZoneHistoryKey(bundleID: "com.example.Clock", displayUUID: display.persistentID!.uuid,
                                    spaceScope: .common, layoutID: persistedLayout.id)
        layout.recordAppZoneHistory(key: key, expectedLayout: persistedLayout, zoneIDs: [0])
        let didFlushHistory = await layout.flush()
        XCTAssertTrue(didFlushHistory)

        let token = RuntimeWindowToken(id: UUID(), pid: 33101, processGeneration: UUID())
        let clock = RecordingAutoRestoreClock()
        let runtime = RetryReadinessRuntime(token: token, clock: clock)
        let controller = AutoRestoreController(layout: layout, runtime: runtime, clock: clock,
                                               cursorLocationProvider: { CGPoint(x: -10_000, y: -10_000) })
        controller.restoreNewWindow(WindowObservationCandidate(token: token, readiness: .temporarilyUnavailable),
                                    bundleID: "com.example.Clock")
        try await eventually { controller.activeEpisodeCount == 0 }
        let attempts = await runtime.observationTimes
        XCTAssertEqual(attempts, [0, 100, 300, 700, 1_500].map { UInt64($0) * 1_000_000 },
                       "Each AX retry targets the episode's absolute offset; AX time does not accumulate into later starts.")
        XCTAssertEqual(clock.sleepDurations, [50, 150, 350, 750].map { UInt64($0) * 1_000_000 })
        let observationCount = await runtime.observationCount
        XCTAssertEqual(observationCount, 5)
    }
        func testExpiredEnumerationDeadlineIsNotStoredAndFreshRuntimeTicketsCanOperate() async throws {
        let effects = RetryProbePlacementEffects(failFirstPosition: false)
        let recorder = OperationDeadlineRecorder()
        let runtime = AccessibilityWindowRuntime(
            focusedWindowValidator: { recorder.record($0.operationDeadline, timeout: $0.messagingTimeout) },
            accessibilityTrustedProvider: { true },
            mover: WindowMover(effects: effects),
            historyMover: WindowMover(messagingTimeout: 0.2, retryLimit: 0, effects: effects),
            settableAttributeProvider: { window, _ in recorder.record(window.operationDeadline); return true },
            historyObserverProvider: { _, _, _, _ in true }
        )
        let pid: pid_t = 33102
        let element = AXUIElementCreateApplication(pid)
        let expiredDeadline: UInt64 = 1
        let expiredEnumerationWindow = AXWindow(applicationElement: element, element: element, pid: pid,
                                                messagingTimeout: 0.2, operationDeadline: expiredDeadline)
        let token = try await runtime.token(for: expiredEnumerationWindow)
        let storedDeadline = await runtime.storedOperationDeadline(for: token)
        XCTAssertNil(storedDeadline,
                     "Runtime records retain AX identity and a normal timeout, never a snapshot's operation deadline.")
        let historyLease = RuntimeHistoryLeaseID()
        let historyLeaseRetained = await runtime.retainHistoryLease(token, lease: historyLease)
        XCTAssertTrue(historyLeaseRetained)

        let historyTicket = pendingTicket()
        let historyFrame = CGRect(x: 20, y: 30, width: 500, height: 300)
        let actualHistoryFrame = try await runtime.moveHistoryWindow(token, lease: historyLease, to: historyFrame,
                                                                      ticket: historyTicket, preflight: { true })
        XCTAssertEqual(actualHistoryFrame, historyFrame)
        let manualLease = ManualWindowLeaseID()
        let manualLeaseRetained = await runtime.retainManualLease(token, lease: manualLease)
        XCTAssertTrue(manualLeaseRetained)
        let manualTicket = pendingTicket()
        let manualFrame = CGRect(x: 40, y: 50, width: 450, height: 280)
        let actualManualFrame = try await runtime.moveManualWindow(token, lease: manualLease, to: manualFrame,
                                                                    ticket: manualTicket, preflight: { true })
        XCTAssertEqual(actualManualFrame, manualFrame)
        XCTAssertTrue(recorder.deadlines.contains { ($0 ?? 0) > DispatchTime.now().uptimeNanoseconds })
        XCTAssertEqual(recorder.operationTimeouts.count, 2)
        if recorder.operationTimeouts.count == 2 {
            XCTAssertEqual(recorder.operationTimeouts[0], 0.2, accuracy: 0.001,
                           "Automatic placement caps AX calls at 200 ms.")
            XCTAssertEqual(recorder.operationTimeouts[1], 0.5, accuracy: 0.001,
                           "Ordinary manual placement retains its 500 ms AX timeout.")
        }

        let attemptsBeforeExpiredTicket = effects.positionAttempts
        let expiredTicket = PlacementCommitTicket(startDeadline: 1, totalDeadline: 1)
        do {
            _ = try await runtime.moveHistoryWindow(token, lease: historyLease, to: historyFrame,
                                                    ticket: expiredTicket, preflight: { true })
            XCTFail("An expired operation ticket must not perform a setter.")
        } catch { }
        XCTAssertEqual(effects.positionAttempts, attemptsBeforeExpiredTicket)
    }
    func testInboxCoalescesCallbacksAndBoundsOverflowToOneEpochSignal() {
        let tickets = AutoRestoreTicketRegistry()
        let inbox = NewWindowSignalInbox(ticketRegistry: tickets)
        let tokenTicket = PlacementCommitTicket(startDeadline: .max, totalDeadline: .max)
        tickets.register(tokenTicket, id: UUID())
        let generation = UUID()
        let duplicate = NewWindowSignal(kind: .created, pid: 50, generation: generation,
                                        launchDate: nil, bundleID: nil, duringBaseline: true,
                                        afterBaseline: false, epoch: 3)
        XCTAssertTrue(inbox.enqueue(duplicate).shouldDrain)
        XCTAssertFalse(inbox.enqueue(duplicate).shouldDrain)
        XCTAssertEqual(inbox.takeBatch().signals.count, 1)

        for pid in pid_t(100) ..< pid_t(228) {
            _ = inbox.enqueue(NewWindowSignal(kind: .launch, pid: pid, generation: nil,
                                              launchDate: nil, bundleID: nil, duringBaseline: false,
                                              afterBaseline: true, epoch: 3))
        }
        let firstOverflow = inbox.enqueue(NewWindowSignal(kind: .launch, pid: 999, generation: nil,
                                                          launchDate: nil, bundleID: nil, duringBaseline: false,
                                                          afterBaseline: true, epoch: 3))
        XCTAssertTrue(firstOverflow.overflowed)
        XCTAssertEqual(tokenTicket.state, .invalidated, "Overflow synchronously invalidates registered auto tickets.")
        let repeatedOverflow = inbox.enqueue(NewWindowSignal(kind: .launch, pid: 1000, generation: nil,
                                                             launchDate: nil, bundleID: nil, duringBaseline: false,
                                                             afterBaseline: true, epoch: 3))
        XCTAssertFalse(repeatedOverflow.overflowed, "The same inbox overflow episode is signaled only once.")
        for pid in pid_t(2_000) ..< pid_t(12_000) {
            _ = inbox.enqueue(NewWindowSignal(kind: .created, pid: pid, generation: generation,
                                              launchDate: nil, bundleID: nil, duringBaseline: false,
                                              afterBaseline: true, epoch: 3))
        }
        XCTAssertTrue(inbox.takeBatch().overflowed, "A callback flood cannot schedule a second overflow restart within one epoch.")
        inbox.advanceEpoch(4)
        XCTAssertEqual(inbox.enqueue(NewWindowSignal(kind: .launch, pid: 77, generation: nil,
                                                     launchDate: nil, bundleID: nil, duringBaseline: false,
                                                     afterBaseline: true, epoch: 3)).shouldDrain, false,
                       "Late callbacks from an invalidated epoch are ignored.")
        XCTAssertFalse(inbox.finishDrain())
        XCTAssertTrue(inbox.enqueue(NewWindowSignal(kind: .launch, pid: 78, generation: nil,
                                                    launchDate: nil, bundleID: nil, duringBaseline: false,
                                                    afterBaseline: true, epoch: 4)).shouldDrain,
                      "The next epoch can schedule one fresh drain.")
    }}
