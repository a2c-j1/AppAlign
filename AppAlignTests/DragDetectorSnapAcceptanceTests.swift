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

    init() {
        let fixture = DragFixture()
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: PersistentDisplayID(uuid: UUID()),
                              sessionID: UUID(), name: "Acceptance display", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800), isPrimary: true, backingScaleFactor: 1)
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)))
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
        XCTAssertEqual(flow.overlay.selected, firstZone.id)

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
        XCTAssertEqual(flow.overlay.selected, firstZone.id)

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
