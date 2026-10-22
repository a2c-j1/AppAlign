import XCTest

extension NewWindowMonitorTests {
@MainActor
    func testDegradedSpaceSkipsAutomaticMoveAndPreservesCommonHistory() async throws {
        let provider = SpaceProvider.production(backend: AutoRestoreUnavailableSpaceBackend())
        let fixture = try await AutoRestoreFixture.make(mismatchedFrame: false, blockSetter: false,
                                                        spaceProvider: provider)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        XCTAssertEqual(fixture.layout.spaceSnapshot(for: fixture.display).mode, .degradedScoped)
        XCTAssertFalse(fixture.layout.spaceSnapshot(for: fixture.display).allowsAutomaticRestore)

        let pid: pid_t = 33991
        let appElement = AXUIElementCreateApplication(pid)
        let token = try await fixture.runtime.token(for: AXWindow(applicationElement: appElement, element: appElement, pid: pid))
        let auto = AutoRestoreController(layout: fixture.layout, runtime: fixture.runtime,
                                         cursorLocationProvider: { fixture.display.frame.origin })
        auto.restoreNewWindow(WindowObservationCandidate(token: token,
                                                         readiness: .ready(CGRect(x: 1_500, y: 1_500, width: 300, height: 200))),
                              bundleID: "com.example.Auto")
        try await eventually { auto.activeEpisodeCount == 0 && auto.inFlightEpisodeCount == 0 }

        XCTAssertEqual(fixture.mover.returnedCount, 0, "The real automatic controller must not move a window in degraded mode.")
        XCTAssertTrue(fixture.layout.appZoneHistoryRetryRecords.isEmpty)
        let stored = try await fixture.store.load()
        let historyKey = AppZoneHistoryKey(bundleID: "com.example.Auto", displayUUID: fixture.display.persistentID!.uuid,
                                           spaceScope: .common, layoutID: fixture.persistedLayout.id)
        XCTAssertEqual(stored.appZoneHistory[historyKey]?.revision, 1,
                       "A preexisting common history record must not be pruned or rewritten in degraded mode.")
    }

@MainActor
    func testCursorPreferenceUsesGlobalScreenCoordinatesForNegativeVerticalDisplay() {
        let upper = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: PersistentDisplayID(uuid: UUID()),
                            sessionID: UUID(), name: "Upper", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                            workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800), isPrimary: true, backingScaleFactor: 1)
        let lower = Display(runtimeID: RuntimeDisplayID(rawValue: 2), persistentID: PersistentDisplayID(uuid: UUID()),
                            sessionID: UUID(), name: "Lower", frame: CGRect(x: 0, y: -800, width: 1_000, height: 800),
                            workArea: CGRect(x: 0, y: -800, width: 1_000, height: 800), isPrimary: false, backingScaleFactor: 1)
        let order = AutoRestoreController.displayPreferenceOrder(
            displays: [upper, lower], windowFrame: CGRect(x: 2_000, y: 2_000, width: 100, height: 100),
            cursor: CGPoint(x: 500, y: -400)
        )
        XCTAssertEqual(order.first?.id, lower.id, "The CGEvent global point on a negative-y display must win over the primary display.")
    }

@MainActor
    func testCancelDuringRuntimeSetterKeepsAutoTicketOccupiedUntilBackendReturns() async throws {
        let fixture = try await AutoRestoreFixture.make(mismatchedFrame: false, blockSetter: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let pid: pid_t = 33001
        let appElement = AXUIElementCreateApplication(pid)
        let window = AXWindow(applicationElement: appElement, element: appElement, pid: pid)
        let token = try await fixture.runtime.token(for: window)
        let auto = AutoRestoreController(layout: fixture.layout, runtime: fixture.runtime,
                                         cursorLocationProvider: { fixture.display.frame.origin })
        auto.restoreNewWindow(WindowObservationCandidate(token: token, readiness: .ready(CGRect(x: 1_500, y: 1_500, width: 300, height: 200))),
                              bundleID: "com.example.Auto")
        await fixture.mover.waitUntilEntered()
        XCTAssertEqual(auto.inFlightEpisodeCount, 1)

        auto.cancelAll()
        XCTAssertEqual(auto.activeEpisodeCount, 0)
        XCTAssertEqual(auto.inFlightEpisodeCount, 1, "The cancelled episode remains in-flight while the backend setter is blocked.")
        let now = DispatchTime.now().uptimeNanoseconds
        let queuedManualTicket = try XCTUnwrap(fixture.layout.placementValidity.reserve(
            startDeadline: now + 2_000_000_000, totalDeadline: now + 5_000_000_000
        ))
        XCTAssertFalse(queuedManualTicket.beginWrite(now: DispatchTime.now().uptimeNanoseconds),
                       "A manual/keyboard commit cannot pass the shared write gate while the cancelled auto backend is still inside its setter.")
        let unrelatedTicket = PlacementCommitTicket(startDeadline: now + 2_000_000_000, totalDeadline: now + 5_000_000_000)
        XCTAssertEqual(unrelatedTicket.state, .pending, "Auto cancellation invalidates only tickets registered to its own episode.")

        var shutdownStarted = false
        var shutdownDrained = false
        let shutdown = Task { @MainActor in
            shutdownStarted = true
            await auto.drainForShutdown()
            shutdownDrained = true
        }
        try await eventually { shutdownStarted }
        XCTAssertFalse(shutdownDrained, "Quit drain waits while the automatic mover is still inside its setter.")
        fixture.mover.releaseSetter()
        await shutdown.value
        XCTAssertTrue(shutdownDrained)
        XCTAssertEqual(auto.inFlightEpisodeCount, 0)
        try await eventually { queuedManualTicket.beginWrite(now: DispatchTime.now().uptimeNanoseconds) }
        XCTAssertTrue(unrelatedTicket.beginWrite(now: DispatchTime.now().uptimeNanoseconds))
        queuedManualTicket.finish()
        unrelatedTicket.finish()
    }
@MainActor
    func testCancelledObservationEpisodesKeepEightInFlightSlotsUntilShutdownDrain() async throws {
        let fixture = try await AutoRestoreFixture.make(mismatchedFrame: false, blockSetter: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let tokens = (0 ..< 8).map { index in
            RuntimeWindowToken(id: UUID(), pid: pid_t(44000 + index))
        }
        let runtime = BlockingAutoObservationRuntime(tokens: tokens)
        let auto = AutoRestoreController(layout: fixture.layout, runtime: runtime,
                                         cursorLocationProvider: { fixture.display.frame.origin })
        for token in tokens {
            auto.restoreNewWindow(WindowObservationCandidate(token: token, readiness: .temporarilyUnavailable),
                                  bundleID: "com.example.Auto")
        }
        await runtime.waitUntilObserved(count: 8)
        XCTAssertEqual(auto.inFlightEpisodeCount, 8)
        XCTAssertEqual(auto.activeEpisodeCount, 8)

        auto.cancelAll()
        auto.resume()
        for token in tokens {
            auto.restoreNewWindow(WindowObservationCandidate(token: token, readiness: .temporarilyUnavailable),
                                  bundleID: "com.example.Auto")
        }
        XCTAssertEqual(auto.activeEpisodeCount, 0,
                       "Cancelled tasks keep their capacity slots while a backend observation is unresolved.")
        XCTAssertEqual(auto.inFlightEpisodeCount, 8)

        var drainStarted = false
        var drained = false
        let shutdown = Task { @MainActor in
            drainStarted = true
            await auto.drainForShutdown()
            drained = true
        }
        try await eventually { drainStarted }
        XCTAssertFalse(drained, "Quit waits for all automatic runtime awaits to return.")
        await runtime.releaseObservations()
        await shutdown.value
        XCTAssertTrue(drained)
        XCTAssertEqual(auto.inFlightEpisodeCount, 0)
        try await eventually { fixture.layout.appHistoryCoordinator.assignedTokenCount == 0 }
    }
@MainActor
    func testAutoRestoreRejectsFiniteButMismatchedRuntimeReadback() async throws {
        let fixture = try await AutoRestoreFixture.make(mismatchedFrame: true, blockSetter: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let pid: pid_t = 33002
        let appElement = AXUIElementCreateApplication(pid)
        let token = try await fixture.runtime.token(for: AXWindow(applicationElement: appElement, element: appElement, pid: pid))
        let auto = AutoRestoreController(layout: fixture.layout, runtime: fixture.runtime,
                                         cursorLocationProvider: { CGPoint(x: -10_000, y: -10_000) })
        auto.restoreNewWindow(WindowObservationCandidate(token: token, readiness: .ready(CGRect(x: 1_500, y: 1_500, width: 300, height: 200))),
                              bundleID: "com.example.Auto")
        try await eventually {
            fixture.mover.returnedCount == 1 && auto.activeEpisodeCount == 0 && auto.inFlightEpisodeCount == 0
        }
        XCTAssertEqual(fixture.mover.returnedFrames.count, 1)
        XCTAssertTrue(DisplayGeometry.isFinite(fixture.mover.returnedFrames[0]))
        XCTAssertFalse(fixture.layout.appHistoryCoordinator.isAssigned(token: token))
        try await eventually { await fixture.runtime.historyLeaseCount(for: token) == 0 }
        let nextLease = fixture.layout.reserveAppPlacement(token: token, bundleID: "com.example.Auto",
                                                           display: fixture.display, layout: fixture.persistedLayout)
        XCTAssertNotNil(nextLease, "A mismatched automatic attempt must finish its own episode and leave the normal reservation gate available.")
        fixture.layout.releaseAppPlacement(nextLease)
        let persisted = try await fixture.store.load()
        let key = AppZoneHistoryKey(bundleID: "com.example.Auto", displayUUID: fixture.display.persistentID!.uuid,
                                    spaceScope: .common, layoutID: fixture.persistedLayout.id)
        XCTAssertEqual(persisted.appZoneHistory[key]?.revision, 1,
                       "Finite readback outside the requested frame must release the runtime lease without accepting or rewriting history.")
    }
@MainActor
    func testSuccessfulAutomaticRestoreKeepsAssignmentAndRuntimeHistoryLease() async throws {
        let fixture = try await AutoRestoreFixture.make(mismatchedFrame: false, blockSetter: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let pid: pid_t = 33004
        let element = AXUIElementCreateApplication(pid)
        let token = try await fixture.runtime.token(for: AXWindow(applicationElement: element, element: element, pid: pid))
        let auto = AutoRestoreController(layout: fixture.layout, runtime: fixture.runtime,
                                         cursorLocationProvider: { CGPoint(x: -10_000, y: -10_000) })
        auto.restoreNewWindow(WindowObservationCandidate(token: token, readiness: .ready(CGRect(x: 1_500, y: 1_500, width: 300, height: 200))),
                              bundleID: "com.example.Auto")
        try await eventually { fixture.mover.returnedCount == 1 && auto.activeEpisodeCount == 0 }
        XCTAssertTrue(fixture.layout.appHistoryCoordinator.isAssigned(token: token))
        let retainedHistoryLeaseCount = await fixture.runtime.historyLeaseCount(for: token)
        XCTAssertEqual(retainedHistoryLeaseCount, 1)
    }
@MainActor
    func testTerminalCandidateEndsWithoutRetryAndSpaceChangeInvalidatesAutoTickets() async throws {
        let fixture = try await AutoRestoreFixture.make(mismatchedFrame: false, blockSetter: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let pid: pid_t = 33005
        let element = AXUIElementCreateApplication(pid)
        let token = try await fixture.runtime.token(for: AXWindow(applicationElement: element, element: element, pid: pid))
        let auto = AutoRestoreController(layout: fixture.layout, runtime: fixture.runtime,
                                         cursorLocationProvider: { CGPoint(x: -10_000, y: -10_000) })
        auto.restoreNewWindow(WindowObservationCandidate(token: token, readiness: .terminal), bundleID: "com.example.Auto")
        XCTAssertEqual(auto.activeEpisodeCount, 0)
        XCTAssertEqual(fixture.mover.returnedCount, 0)
        let terminalLeaseCount = await fixture.runtime.historyLeaseCount(for: token)
        XCTAssertEqual(terminalLeaseCount, 0)

        let registry = AutoRestoreTicketRegistry()
        let ticket = PlacementCommitTicket(startDeadline: .max, totalDeadline: .max)
        registry.register(ticket, id: UUID())
        let monitor = NewWindowMonitor(layout: fixture.layout, runtime: fixture.runtime,
                                       ticketRegistry: registry, ownPID: -1)
        var environmentChangeCount = 0
        monitor.onEnvironmentChanged = { environmentChangeCount += 1 }
        monitor.spaceChanged()
        XCTAssertEqual(ticket.state, .invalidated, "A Space transition synchronously invalidates only automatic tickets in its registry.")
        XCTAssertEqual(environmentChangeCount, 1)
    }}

private struct AutoRestoreUnavailableSpaceBackend: ReadOnlySpaceBackend {
    let identifier = "auto-restore-unavailable"
    let canAdoptStableIdentifiers = true
    func snapshot(for displayUUID: UUID) async throws -> ReadOnlySpaceValue? { nil }
}
