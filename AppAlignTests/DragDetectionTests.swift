import Foundation
import XCTest

final class DragDetectionTests: XCTestCase {
    func testMailboxCoalescesOnlyAdjacentMovesAndKeepsBarriersInOrder() {
        var mailbox = DragMailbox(capacity: 8)
        mailbox.enqueue(kind: .leftDown)
        mailbox.enqueue(kind: .leftDragged, location: CGPoint(x: 21, y: 21))
        mailbox.enqueue(kind: .leftDragged, location: CGPoint(x: 24, y: 24))
        mailbox.enqueue(kind: .flagsChanged, flags: 1)
        mailbox.enqueue(kind: .leftDragged)
        mailbox.enqueue(kind: .tapDisabled)
        mailbox.enqueue(kind: .leftUp)
        let events = mailbox.drain()
        XCTAssertEqual(events.map(\.kind), [.leftDown, .leftDragged, .flagsChanged, .leftDragged, .tapDisabled, .leftUp])
        XCTAssertEqual(events.map(\.sequence), [1, 3, 4, 5, 6, 7])
        XCTAssertEqual(events[1].location, CGPoint(x: 24, y: 24))
        XCTAssertEqual(Set(events.map(\.gesture)), [1])
    }

    func testMailboxHasFinitePrefixAndReservedOverflowTerminal() {
        var mailbox = DragMailbox(capacity: 3)
        for kind in [DragInputKind.leftDown, .flagsChanged, .leftUp, .leftDown] { mailbox.enqueue(kind: kind) }
        for _ in 0 ..< 10_000 { mailbox.enqueue(kind: .leftDragged) }
        let events = mailbox.drain()
        XCTAssertEqual(events.map(\.kind), [.leftDown, .flagsChanged, .leftUp, .overflow])
        XCTAssertEqual(events.map(\.sequence), [1, 2, 3, 4])
        XCTAssertEqual(events.last?.epoch, 1)
        XCTAssertTrue(mailbox.overflowed)
        XCTAssertEqual(mailbox.drain().count, 0)
    }

    @MainActor
    func testAccessibilityIsRequestedOnlyWhenDragIsEnabled() {
        let fixture = DragFixture()
        fixture.context.accessibility = false
        fixture.controller.setEnabled(true)
        XCTAssertEqual(fixture.context.accessibilityRequests, 1)
        XCTAssertEqual(fixture.monitor.starts, 0)
        fixture.context.accessibility = true
        fixture.controller.retry()
        XCTAssertEqual(fixture.monitor.starts, 1)
        fixture.monitor.status(.ready)
        XCTAssertTrue(fixture.controller.isRunning)
        fixture.stop()
    }

    @MainActor
    func testMonitoringStartsWhenAccessibilityBecomesAvailable() async throws {
        let fixture = DragFixture()
        fixture.context.accessibility = false
        fixture.controller.setEnabled(true)
        XCTAssertEqual(fixture.monitor.starts, 0)
        fixture.context.accessibility = true
        try await spin { fixture.monitor.starts == 1 }
        fixture.monitor.status(.ready)
        XCTAssertTrue(fixture.controller.isRunning)
        fixture.stop()
    }

    @MainActor
    func testMonitoringStartsAfterMouseButtonIsReleased() async throws {
        let fixture = DragFixture()
        fixture.context.released = false
        fixture.controller.setEnabled(true)
        XCTAssertEqual(fixture.monitor.starts, 0)
        fixture.context.released = true
        try await spin { fixture.monitor.starts == 1 }
        fixture.stop()
    }

    @MainActor
    func testSameWindowIDMovesWithPointerAndResolvesAfterRelease() async throws {
        let fixture = DragFixture()
        fixture.start()
        try await fixture.becomeMoving()
        fixture.send(.leftUp, gesture: 1, point: CGPoint(x: 10, y: 0))
        try await spin { fixture.controller.lifecycleEvents.last?.kind == .ended }
        XCTAssertEqual(fixture.controller.lifecycleEvents.map(\.kind).filter { $0 == .began }.count, 1)
        let captureCount = await fixture.reader.captureCount
        XCTAssertEqual(captureCount, 1)
        try await spin { await fixture.reader.leaseCount == 0 }
        fixture.stop()
    }

    @MainActor
    func testPointerMotionWithoutWindowMotionDoesNotStart() {
        let fixture = DragFixture()
        fixture.start()
        fixture.send(.leftDown, gesture: 1)
        fixture.send(.leftDragged, gesture: 1, point: CGPoint(x: 40, y: 0))
        XCTAssertFalse(fixture.controller.lifecycleEvents.contains { $0.kind == .began })
        fixture.send(.leftUp, gesture: 1, point: CGPoint(x: 40, y: 0))
        XCTAssertEqual(fixture.controller.lifecycleEvents.last?.kind, .cancelled)
        fixture.stop()
    }

    @MainActor
    func testReleaseDoesNotPlaceWindowLeftBehindByPointer() async throws {
        let fixture = DragFixture()
        fixture.start()
        try await fixture.becomeMoving()
        fixture.send(.leftDragged, gesture: 1, point: CGPoint(x: 80, y: 0))
        fixture.send(.leftUp, gesture: 1, point: CGPoint(x: 80, y: 0))
        XCTAssertEqual(fixture.controller.lifecycleEvents.last?.kind, .cancelled)
        let captures = await fixture.reader.captureCount
        XCTAssertEqual(captures, 0)
        fixture.stop()
    }

    @MainActor
    func testDisappearingWindowCancelsImmediately() async throws {
        let fixture = DragFixture()
        fixture.start()
        try await fixture.becomeMoving()
        fixture.context.windowFrame = nil
        fixture.send(.leftDragged, gesture: 1, point: CGPoint(x: 20, y: 0))
        XCTAssertEqual(fixture.controller.lifecycleEvents.last?.kind, .cancelled)
        XCTAssertFalse(fixture.context.gate)
        fixture.stop()
    }

    @MainActor
    func testReleaseUnderDifferentWindowDoesNotResolveAXTarget() async throws {
        let fixture = DragFixture()
        fixture.start()
        try await fixture.becomeMoving()
        fixture.context.downWindow = DownWindowBaseline(pid: 2, frame: CGRect(x: 10, y: 0, width: 400, height: 300),
                                                        windowID: 43)
        fixture.send(.leftUp, gesture: 1, point: CGPoint(x: 10, y: 0))
        XCTAssertEqual(fixture.controller.lifecycleEvents.last?.kind, .cancelled)
        let captureCount = await fixture.reader.captureCount
        XCTAssertEqual(captureCount, 0)
        fixture.stop()
    }

    @MainActor
    func testAXTargetMustMatchMouseDownProcess() async throws {
        let fixture = DragFixture()
        fixture.context.downWindow = DownWindowBaseline(pid: 3, frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                                                        windowID: 42)
        fixture.start()
        try await fixture.becomeMoving()
        fixture.send(.leftUp, gesture: 1, point: CGPoint(x: 10, y: 0))
        try await spin { fixture.controller.lifecycleEvents.last?.kind == .cancelled }
        try await spin { await fixture.reader.leaseCount == 0 }
        fixture.stop()
    }

    @MainActor
    func testDelayedAXResolutionCannotCommitEarlierGesture() async throws {
        let fixture = DragFixture()
        fixture.start()
        try await fixture.becomeMoving()
        await fixture.reader.blockCapture()
        fixture.send(.leftUp, gesture: 1, point: CGPoint(x: 10, y: 0))
        try await spin { await fixture.reader.captureBlocked }
        fixture.context.windowFrame = CGRect(x: 0, y: 0, width: 400, height: 300)
        fixture.send(.leftDown, gesture: 2)
        await fixture.reader.resumeCapture()
        try await spin { await fixture.reader.leaseCount == 0 }
        XCTAssertFalse(fixture.controller.lifecycleEvents.contains { $0.kind == .ended && $0.session == 1 })
        fixture.stop()
    }

    @MainActor
    func testRevokedPermissionStopsMonitoringAndCancelsGesture() async throws {
        let fixture = DragFixture()
        fixture.start()
        try await fixture.becomeMoving()
        fixture.context.accessibility = false
        fixture.controller.checkHealth()
        XCTAssertFalse(fixture.controller.isRunning)
        XCTAssertEqual(fixture.controller.lifecycleEvents.last?.kind, .cancelled)
        XCTAssertEqual(fixture.context.invalidations, 1)
    }
}
