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
        fixture.controller.onWillResolveWindow = { snap.hideOverlayForWindowLookup() }
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
        let frame = CGRect(x: point.x, y: point.y, width: 400, height: 300)
        fixture.context.windowFrame = frame
        await fixture.reader.setFrame(frame)
        fixture.send(.leftDragged, gesture: 1, point: point, flags: CGEventFlags.maskShift.rawValue)
    }

    func finish(at point: CGPoint) {
        fixture.send(.leftUp, gesture: 1, point: point, flags: CGEventFlags.maskShift.rawValue)
    }

    func assertDrained(file: StaticString = #filePath, line: UInt = #line) async throws {
        try await spin {
            let owners = await fixture.reader.ownerSnapshot
            let leaseCount = await fixture.reader.leaseCount
            return !fixture.controller.windowServerResolutionInFlight && leaseCount == 0 &&
                owners.dragLeases.isEmpty && owners.dragCommits.isEmpty
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

        let releasedFrame = CGRect(x: secondPoint.x, y: secondPoint.y, width: 400, height: 300)
        flow.fixture.context.windowFrame = releasedFrame
        await flow.fixture.reader.setFrame(releasedFrame)
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
        let releasedFrame = CGRect(x: point.x, y: point.y, width: 400, height: 300)
        flow.fixture.context.windowFrame = releasedFrame
        await flow.fixture.reader.setFrame(releasedFrame)
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

        let releasedFrame = CGRect(x: point.x, y: point.y, width: 400, height: 300)
        flow.fixture.context.windowFrame = releasedFrame
        await flow.fixture.reader.setFrame(releasedFrame)
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
        let moved = CGRect(x: target.x, y: target.y, width: 400, height: 300)
        flow.fixture.context.windowFrame = moved
        await flow.fixture.reader.setFrame(moved)
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
