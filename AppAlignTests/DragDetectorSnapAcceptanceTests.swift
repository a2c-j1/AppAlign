import AppKit
import CoreGraphics
import XCTest

@MainActor
private struct WiredDragSnapFlow {
    let fixture: DragFixture
    let layout: LayoutController
    let snap: DragSnapController
    let overlay: FakeZoneOverlay
    private let gate: TestDragGate

    init(storeCoordinator: PersistentStoreCoordinator? = nil) {
        let fixture = DragFixture()
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: PersistentDisplayID(uuid: UUID()),
                              sessionID: UUID(), name: "Acceptance display", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800), isPrimary: true, backingScaleFactor: 1)
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)),
                                      storeCoordinator: storeCoordinator)
        let overlay = FakeZoneOverlay()
        let snap = DragSnapController(layoutController: layout, runtime: fixture.reader, overlay: overlay)
        let gate = TestDragGate()
        self.fixture = fixture
        self.layout = layout
        self.overlay = overlay
        self.snap = snap
        self.gate = gate
        fixture.controller.onWillEnd = { snap.prepareCommit($0) }
        fixture.controller.onAcceptedInput = { snap.acceptedInput($0) }
        fixture.controller.onCommitCancelled = { snap.cancel(reason: $0) }
        fixture.controller.onLifecycle = { snap.lifecycle($0) }
        fixture.controller.dragGateChanged = { gate.setDrag($0) }
        snap.gateChanged = { gate.recordCommit($0) }
    }

    func startMoving() async throws {
        fixture.start()
        try await fixture.becomeMoving()
    }

    func zones() throws -> (Zone, Zone) {
        let snapshot = try XCTUnwrap(layout.appliedDragLayoutSnapshot(at: CGPoint(x: 10, y: 10)))
        guard snapshot.zones.count >= 2 else { throw DragTestError.unavailable }
        return (snapshot.zones[0], snapshot.zones[1])
    }

    func sendShift(at point: CGPoint, down: Bool) {
        fixture.send(.flagsChanged, gesture: 1, point: point,
                     flags: down ? CGEventFlags.maskShift.rawValue : 0)
    }

    func drag(to point: CGPoint) async throws {
        await fixture.reader.setFrame(CGRect(x: point.x, y: point.y, width: 400, height: 300))
        fixture.send(.leftDragged, gesture: 1, point: point, flags: CGEventFlags.maskShift.rawValue)
        try await spin { fixture.controller.frameRequestCount == 0 }
    }

    func finish(at point: CGPoint) {
        fixture.send(.leftUp, gesture: 1, point: point, flags: CGEventFlags.maskShift.rawValue)
    }

    func assertDrained(file: StaticString = #filePath, line: UInt = #line) async throws {
        try await spin {
            let owners = await fixture.reader.ownerSnapshot
            let leaseCount = await fixture.reader.leaseCount
            return leaseCount == 0 && owners.dragLeases.isEmpty && owners.dragCommits.isEmpty
        }
        let owners = await fixture.reader.ownerSnapshot
        XCTAssertTrue(owners.dragLeases.isEmpty, file: file, line: line)
        XCTAssertTrue(owners.dragCommits.isEmpty, file: file, line: line)
    }
}

final class DragFinalReleaseAcceptanceTests: XCTestCase {
    @MainActor
    func testShiftReleasedBeforeLeftUpDoesNotPlaceAtStationaryPointer() async throws {
        let flow = WiredDragSnapFlow()
        try await flow.startMoving()
        let point = CGPoint(x: 10, y: 0)
        flow.sendShift(at: point, down: true)
        XCTAssertTrue(flow.overlay.isVisible)
        flow.sendShift(at: point, down: false)
        flow.fixture.send(.leftUp, gesture: 1, point: point)
        try await flow.assertDrained()

        let writes = await flow.fixture.reader.commitCount
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(flow.overlay.isVisible)
        flow.fixture.stop()
    }

    @MainActor
    func testFinalLeftUpOutsideAllZonesDoesNotUseEarlierDraggedSelection() async throws {
        let flow = WiredDragSnapFlow()
        try await flow.startMoving()
        let (firstZone, _) = try flow.zones()
        let firstPoint = CGPoint(x: firstZone.frame.midX, y: firstZone.frame.midY)
        flow.sendShift(at: CGPoint(x: 10, y: 0), down: true)
        try await flow.drag(to: firstPoint)
        XCTAssertEqual(flow.overlay.selected, [firstZone.id])

        flow.finish(at: CGPoint(x: -100, y: -100))
        try await flow.assertDrained()
        let writes = await flow.fixture.reader.commitCount
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(flow.overlay.isVisible)
        flow.fixture.stop()
    }

    @MainActor
    func testFinalLeftUpInAnotherZoneCommitsThatZoneRatherThanEarlierSelection() async throws {
        let flow = WiredDragSnapFlow()
        try await flow.startMoving()
        let (firstZone, secondZone) = try flow.zones()
        let firstPoint = CGPoint(x: firstZone.frame.midX, y: firstZone.frame.midY)
        let secondPoint = CGPoint(x: secondZone.frame.midX, y: secondZone.frame.midY)
        flow.sendShift(at: CGPoint(x: 10, y: 0), down: true)
        try await flow.drag(to: firstPoint)
        XCTAssertEqual(flow.overlay.selected, [firstZone.id])

        flow.finish(at: secondPoint)
        try await spin { await flow.fixture.reader.commitCount == 1 }
        try await spin { !flow.snap.isCommitting }
        try await flow.assertDrained()
        let actual = await flow.fixture.reader.currentFrameValue()
        let writes = await flow.fixture.reader.commitCount
        XCTAssertEqual(actual, secondZone.frame)
        XCTAssertEqual(writes, 1)
        XCTAssertNotEqual(firstZone.frame, secondZone.frame)
        XCTAssertFalse(flow.overlay.isVisible)
        flow.fixture.stop()
    }

    @MainActor
    func testAcceptedLayoutSwitchBarrierThenImmediateUpUsesFreshLayout() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Issue10QuickSwitch-\(UUID().uuidString)", isDirectory: true)
        let coordinator = PersistentStoreCoordinator(directory: directory)
        let layoutID = UUID()
        let nextLayout = PersistedLayout(
            id: layoutID,
            definition: .grid(GridLayout(id: LayoutID(rawValue: layoutID), rows: 1, columns: 2,
                                         rowPercentages: [10_000], columnPercentages: [5_000, 5_000],
                                         cellChildMap: [[3, 9]])),
            spacing: 0, template: .columns, zoneCount: 2, name: "Quick Layout")
        try await coordinator.saveLayoutAndAssignments([PersistentStoreCoordinator.defaultLayout(), nextLayout], [])
        let flow = WiredDragSnapFlow(storeCoordinator: coordinator)
        defer {
            flow.fixture.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        await flow.layout.loadPersistentState()
        XCTAssertTrue(flow.layout.persistenceReady)

        try await flow.startMoving()
        let point = CGPoint(x: 250, y: 200)
        flow.sendShift(at: point, down: true)
        let oldSnapshot = try XCTUnwrap(flow.layout.appliedDragLayoutSnapshot(at: point))
        let oldRevision = oldSnapshot.placementRevision

        let inbox = OrderedInteractionInbox()
        let switchAccepted = expectation(description: "layout switch accepted before release")
        XCTAssertTrue(inbox.enqueueControl {
            XCTAssertNotNil(flow.layout.applyQuickLayout(nextLayout.id, at: point))
            flow.snap.reselectAfterQuickSwitch(point: point, flags: CGEventFlags.maskShift.rawValue)
            switchAccepted.fulfill()
        })
        await fulfillment(of: [switchAccepted], timeout: 2)

        let newSnapshot = try XCTUnwrap(flow.layout.appliedDragLayoutSnapshot(at: point))
        XCTAssertEqual(newSnapshot.layout.id, nextLayout.id)
        XCTAssertNotEqual(newSnapshot.placementRevision, oldRevision)
        let selected = try XCTUnwrap(ZoneSelectionEngine.selectZones(point: point, zones: newSnapshot.zones,
                                                                      workArea: newSnapshot.display.workArea,
                                                                      radius: CGFloat(flow.layout.dragSettings.selectionRadius),
                                                                      strategy: .smallest))
        let expectedFrame = try XCTUnwrap(ZoneSelectionEngine.union(of: selected.map(\.frame)))

        // This release is the first input after the accepted control barrier.
        flow.finish(at: point)
        try await spin { await flow.fixture.reader.commitCount == 1 }
        try await spin { !flow.snap.isCommitting }
        try await flow.assertDrained()
        let actualFrame = await flow.fixture.reader.currentFrameValue()
        XCTAssertEqual(actualFrame, expectedFrame)
        let writes = await flow.fixture.reader.commitCount
        XCTAssertEqual(writes, 1)
    }
}

private enum DetectorCancellation: CaseIterable {
    case escape, stop, quit
}

private enum GesturePhase: Equatable {
    case moving, commitPending
}

final class DragDetectorCancellationAcceptanceTests: XCTestCase {
    @MainActor
    func testEscapeWhileMovingDrainsWithoutPlacement() async throws {
        try await verifyCancellation(.escape, phase: .moving)
    }

    @MainActor
    func testStopWhileMovingDrainsWithoutPlacement() async throws {
        try await verifyCancellation(.stop, phase: .moving)
    }

    @MainActor
    func testQuitWhileMovingDrainsWithoutPlacement() async throws {
        try await verifyCancellation(.quit, phase: .moving)
    }

    @MainActor
    func testEscapeWhileCommitPendingDrainsWithoutPlacement() async throws {
        try await verifyCancellation(.escape, phase: .commitPending)
    }

    @MainActor
    func testStopWhileCommitPendingDrainsWithoutPlacement() async throws {
        try await verifyCancellation(.stop, phase: .commitPending)
    }

    @MainActor
    func testQuitWhileCommitPendingDrainsWithoutPlacement() async throws {
        try await verifyCancellation(.quit, phase: .commitPending)
    }

    @MainActor
    private func verifyCancellation(_ cancellation: DetectorCancellation, phase: GesturePhase) async throws {
        let flow = WiredDragSnapFlow()
        try await flow.startMoving()
        let (zone, _) = try flow.zones()
        let point = CGPoint(x: zone.frame.midX, y: zone.frame.midY)
        flow.sendShift(at: CGPoint(x: 10, y: 0), down: true)
        try await flow.drag(to: point)
        XCTAssertTrue(flow.overlay.isVisible, "The moving gesture must show the overlay before cancellation.")

        if phase == .commitPending {
            await flow.fixture.reader.blockCommit()
            flow.finish(at: point)
            try await spin { await flow.fixture.reader.commitBlocked }
            let owners = await flow.fixture.reader.ownerSnapshot
            XCTAssertEqual(owners.dragCommits.count, 1, "The pending phase must hold the transferred commit owner.")
        }

        cancelThroughDetector(cancellation, flow: flow, point: point)
        if phase == .commitPending {
            await flow.fixture.reader.resumeCommit()
            try await spin { !flow.snap.isCommitting }
        }
        try await flow.assertDrained()
        flow.fixture.send(.leftUp, gesture: 1, point: point, flags: CGEventFlags.maskShift.rawValue)
        await Task.yield()
        let writes = await flow.fixture.reader.commitCount
        XCTAssertEqual(writes, 0, "\(cancellation)-\(phase) must never place a window.")
        XCTAssertFalse(flow.overlay.isVisible, "\(cancellation)-\(phase) must leave every overlay hidden.")
        try await flow.assertDrained()
        flow.fixture.stop()
    }

    @MainActor
    private func cancelThroughDetector(_ cancellation: DetectorCancellation, flow: WiredDragSnapFlow, point: CGPoint) {
        switch cancellation {
        case .escape:
            flow.fixture.send(.escape, gesture: 1, point: point, flags: CGEventFlags.maskShift.rawValue)
        case .stop:
            flow.fixture.stop()
        case .quit:
            flow.fixture.controller.shutdownForQuit()
        }
    }
}

extension DragFinalReleaseAcceptanceTests {
    @MainActor
    func testQuickSwitchSaveFailureKeepsMovingGestureAndFreshDrop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Issue10QuickSwitchFailure-\(UUID().uuidString)", isDirectory: true)
        let access = Issue10QuickSwitchFileAccess()
        let coordinator = PersistentStoreCoordinator(directory: directory, fileAccess: access)
        let layoutID = UUID()
        let nextLayout = PersistedLayout(
            id: layoutID,
            definition: .grid(GridLayout(id: LayoutID(rawValue: layoutID), rows: 1, columns: 2,
                                         rowPercentages: [10_000], columnPercentages: [5_000, 5_000],
                                         cellChildMap: [[3, 9]])),
            spacing: 0, template: .columns, zoneCount: 2, name: "Quick Layout")
        try await coordinator.saveLayoutAndAssignments([PersistentStoreCoordinator.defaultLayout(), nextLayout], [])
        access.failNextAssignmentWrite()
        let flow = WiredDragSnapFlow(storeCoordinator: coordinator)
        defer {
            flow.fixture.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        await flow.layout.loadPersistentState()
        try await flow.startMoving()

        let point = CGPoint(x: 250, y: 200)
        flow.sendShift(at: point, down: true)
        let inbox = OrderedInteractionInbox()
        let switchAccepted = expectation(description: "quick switch accepted before failed save")
        XCTAssertTrue(inbox.enqueueControl {
            XCTAssertNotNil(flow.layout.applyQuickLayout(nextLayout.id, at: point))
            flow.snap.reselectAfterQuickSwitch(point: point, flags: CGEventFlags.maskShift.rawValue)
            switchAccepted.fulfill()
        })
        await fulfillment(of: [switchAccepted], timeout: 2)
        await flow.layout.saveChain?.value

        XCTAssertTrue(flow.layout.canRetrySave)
        XCTAssertEqual(flow.layout.appliedDragLayoutSnapshot(at: point)?.layout.id, nextLayout.id)
        XCTAssertTrue(flow.overlay.isVisible, "A failed persistence recovery must keep the active gesture selection visible.")
        let snapshot = try XCTUnwrap(flow.layout.appliedDragLayoutSnapshot(at: point))
        let selected = try XCTUnwrap(ZoneSelectionEngine.selectZones(point: point, zones: snapshot.zones,
                                                                      workArea: snapshot.display.workArea,
                                                                      radius: CGFloat(flow.layout.dragSettings.selectionRadius),
                                                                      strategy: .smallest))
        let expectedFrame = try XCTUnwrap(ZoneSelectionEngine.union(of: selected.map(\.frame)))

        flow.finish(at: point)
        try await spin { await flow.fixture.reader.commitCount == 1 }
        try await spin { !flow.snap.isCommitting }
        try await flow.assertDrained()
        let actualFrame = await flow.fixture.reader.currentFrameValue()
        let writes = await flow.fixture.reader.commitCount
        XCTAssertEqual(actualFrame, expectedFrame)
        XCTAssertEqual(writes, 1)
    }
}

private final class Issue10QuickSwitchFileAccess: AtomicFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFailAssignmentWrite = false

    func failNextAssignmentWrite() {
        lock.withLock { shouldFailAssignmentWrite = true }
    }

    func read(_ url: URL) throws -> Data? {
        try LocalAtomicFileAccess().read(url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        let shouldFail = lock.withLock {
            guard shouldFailAssignmentWrite, url.lastPathComponent == "assignments.json" else { return false }
            shouldFailAssignmentWrite = false
            return true
        }
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
        try LocalAtomicFileAccess().writeAtomically(data, to: url)
    }
}

extension DragFinalReleaseAcceptanceTests {
    @MainActor
    func testRangeModifierReleaseWhileShiftInactiveStartsANewAnchor() async throws {
        let flow = WiredDragSnapFlow()
        defer { flow.fixture.stop() }
        try await flow.startMoving()
        let (anchorZone, targetZone) = try flow.zones()
        let anchor = CGPoint(x: anchorZone.frame.midX, y: anchorZone.frame.midY)
        let target = CGPoint(x: targetZone.frame.midX, y: targetZone.frame.midY)
        let shift = CGEventFlags.maskShift.rawValue
        let option = CGEventFlags.maskAlternate.rawValue

        flow.fixture.send(.flagsChanged, gesture: 1, point: anchor, flags: shift | option)
        XCTAssertTrue(flow.overlay.isVisible)
        flow.fixture.send(.flagsChanged, gesture: 1, point: anchor, flags: option)
        XCTAssertFalse(flow.overlay.isVisible)
        flow.fixture.send(.flagsChanged, gesture: 1, point: anchor, flags: 0)
        flow.fixture.send(.flagsChanged, gesture: 1, point: target, flags: option)
        flow.fixture.send(.leftDragged, gesture: 1, point: target, flags: option)
        flow.fixture.send(.flagsChanged, gesture: 1, point: target, flags: option | shift)
        XCTAssertTrue(flow.overlay.isVisible)

        flow.fixture.send(.leftUp, gesture: 1, point: target, flags: option | shift)
        try await flow.assertDrained()
        let actualFrame = await flow.fixture.reader.currentFrameValue()
        let writes = await flow.fixture.reader.commitCount
        XCTAssertEqual(actualFrame, targetZone.frame)
        XCTAssertEqual(writes, 1)
    }
}

final class DragPointerPathTests: XCTestCase {
    func testRecentPointerPathMatchesCurvedAndDelayedWindowFrames() {
        let frame = CGRect(x: 100, y: 80, width: 400, height: 300)
        var curved = DragStateMachine()
        _ = curved.down(session: 1, point: .zero, frame: frame, titleBarHit: true, epoch: 1)
        let first = frame.offsetBy(dx: 20, dy: 0)
        _ = curved.observe(session: 1, point: CGPoint(x: 20, y: 0), frame: first, epoch: 1)
        _ = curved.observe(session: 1, point: CGPoint(x: 20, y: 0), frame: first, epoch: 1)
        let curve = [CGPoint(x: 79.6, y: -37.6), CGPoint(x: 150, y: -60), CGPoint(x: 277.7, y: -71.5)]
        XCTAssertEqual(curved.observe(session: 1, point: curve[0], latestPoint: curve[2], pointerPath: curve,
                                      frame: frame.offsetBy(dx: 150, dy: -60), epoch: 1).map(\.kind), [.updated])

        var delayed = DragStateMachine()
        _ = delayed.down(session: 2, point: .zero, frame: frame, titleBarHit: true, epoch: 1)
        let moved = frame.offsetBy(dx: -20, dy: -20)
        _ = delayed.observe(session: 2, point: CGPoint(x: -20, y: -20), frame: moved, epoch: 1)
        _ = delayed.observe(session: 2, point: CGPoint(x: -20, y: -20), frame: moved, epoch: 1)
        let path = [CGPoint(x: -587, y: -322), CGPoint(x: -623.1, y: -344.5), CGPoint(x: -680.8, y: -377.8)]
        XCTAssertEqual(delayed.observe(session: 2, point: path[1], latestPoint: path[2], pointerPath: path,
                                       frame: frame.offsetBy(dx: -587, dy: -322), epoch: 1).map(\.kind), [.updated])
        for _ in 0 ..< 2 {
            XCTAssertEqual(delayed.observe(session: 2, point: path[1], latestPoint: path[2], pointerPath: Array(path.dropFirst()),
                                           frame: frame.offsetBy(dx: -587, dy: -322), epoch: 1).map(\.kind), [.updated])
        }
        XCTAssertEqual(delayed.observe(session: 2, point: path[1], latestPoint: path[2], pointerPath: Array(path.dropFirst()),
                                       frame: frame.offsetBy(dx: -587, dy: -322), epoch: 1).map(\.kind), [.cancelled])
    }

    func testPointerPathExpiresOldSamplesAndKeepsLatest() {
        var path = DragPointerPath()
        for (time, offsetX) in [(100_000_000, 10), (200_000_000, 20), (450_000_000, 45)] {
            path.append(DragInputEvent(kind: .leftDragged, location: CGPoint(x: offsetX, y: 0), timestamp: UInt64(time)))
        }
        XCTAssertEqual(path.recent(now: 500_000_000), [CGPoint(x: 20, y: 0), CGPoint(x: 45, y: 0)])
        XCTAssertEqual(path.recent(now: 1_000_000_000), [CGPoint(x: 45, y: 0)])
    }

    func testSlowFrameReadRetainsItsRequestPoint() {
        var path = DragPointerPath()
        let request = DragInputEvent(kind: .leftDragged, location: CGPoint(x: 10, y: 0), timestamp: 100_000_000)
        path.append(request)
        path.append(DragInputEvent(kind: .leftDragged, location: CGPoint(x: 45, y: 0), timestamp: 405_000_000))

        let points = path.duringFrameRead(startedAt: 100_000_000, including: request)
        XCTAssertEqual(points, [CGPoint(x: 10, y: 0), CGPoint(x: 45, y: 0)])

        let frame = CGRect(x: 100, y: 80, width: 400, height: 300)
        var detector = DragStateMachine()
        _ = detector.down(session: 1, point: .zero, frame: frame, titleBarHit: true, epoch: 1)
        _ = detector.observe(session: 1, point: CGPoint(x: 10, y: 0), frame: frame.offsetBy(dx: 10, dy: 0), epoch: 1)
        _ = detector.observe(session: 1, point: CGPoint(x: 10, y: 0), frame: frame.offsetBy(dx: 10, dy: 0), epoch: 1)
        XCTAssertEqual(detector.observe(session: 1, point: request.location, latestPoint: CGPoint(x: 45, y: 0),
                                        pointerPath: points, frame: frame.offsetBy(dx: 10, dy: 0), epoch: 1).map(\.kind), [.updated])
    }

    func testFrameReadKeepsPointerHistoryBeforeRequestAndToleratesMovingDivergence() {
        var path = DragPointerPath()
        let earlier = DragInputEvent(kind: .leftDragged, location: CGPoint(x: -136, y: -306), timestamp: 100_000_000)
        let request = DragInputEvent(kind: .leftDragged, location: CGPoint(x: -138.6, y: -355.7), timestamp: 350_000_000)
        path.append(earlier)
        path.append(request)
        path.append(DragInputEvent(kind: .leftDragged, location: CGPoint(x: -127.5, y: -438), timestamp: 450_000_000))
        XCTAssertEqual(path.duringFrameRead(startedAt: 350_000_000, including: request).first, earlier.location)

        let frame = CGRect(x: 100, y: 80, width: 400, height: 300)
        var detector = DragStateMachine()
        _ = detector.down(session: 1, point: .zero, frame: frame, titleBarHit: true, epoch: 1)
        let first = frame.offsetBy(dx: -20, dy: -20)
        _ = detector.observe(session: 1, point: CGPoint(x: -20, y: -20), frame: first, epoch: 1)
        _ = detector.observe(session: 1, point: CGPoint(x: -20, y: -20), frame: first, epoch: 1)
        let diverged = [CGPoint(x: -138.6, y: -355.7), CGPoint(x: -127.5, y: -438)]
        for offset in [CGPoint(x: -136, y: -306), CGPoint(x: -135, y: -320), CGPoint(x: -134, y: -334)] {
            XCTAssertEqual(detector.observe(session: 1, point: request.location, latestPoint: diverged[1],
                                            pointerPath: diverged, frame: frame.offsetBy(dx: offset.x, dy: offset.y), epoch: 1).map(\.kind), [.updated])
        }
    }
}
