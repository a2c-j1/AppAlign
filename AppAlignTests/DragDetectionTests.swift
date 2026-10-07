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

    func testStateRequiresTwoOriginTrackingSamplesAndRejectsResizeAfterBegan() {
        var machine = DragStateMachine()
        let frame = CGRect(x: 100, y: 80, width: 400, height: 300)
        _ = machine.down(session: 1, point: CGPoint(x: 150, y: 90), frame: frame, titleBarHit: true, epoch: 1)
        let moved = frame.offsetBy(dx: 20, dy: 20)
        let point = CGPoint(x: 170, y: 110)
        XCTAssertTrue(machine.observe(session: 1, point: point, frame: moved, epoch: 1).isEmpty)
        XCTAssertEqual(machine.observe(session: 1, point: point, frame: moved, epoch: 1).map(\.kind), [.began, .updated])
        let resized = CGRect(x: 120, y: 100, width: 420, height: 300)
        XCTAssertEqual(machine.observe(session: 1, point: point, frame: resized, epoch: 1).map(\.kind), [.cancelled])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(machine.finish().isEmpty)
    }

    func testNonTitleHitAndUnrelatedOriginNeverBegin() {
        var machine = DragStateMachine()
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        _ = machine.down(session: 1, point: .zero, frame: frame, titleBarHit: false, epoch: 1)
        XCTAssertEqual(machine.state, .idle)
        _ = machine.down(session: 2, point: .zero, frame: frame, titleBarHit: true, epoch: 1)
        for _ in 0 ..< 3 { XCTAssertTrue(machine.observe(session: 2, point: .zero, frame: frame.offsetBy(dx: 50, dy: 0), epoch: 1).isEmpty) }
        XCTAssertEqual(machine.finish().map(\.kind), [.cancelled])
    }

    @MainActor
    func testPermissionRequestsAreExplicitAndRunningWaitsForTapReady() {
        let fixture = DragFixture()
        fixture.context.input = false
        fixture.controller.setEnabled(true)
        XCTAssertEqual(fixture.context.inputRequests, 1)
        XCTAssertEqual(fixture.monitor.starts, 0)
        fixture.context.input = true; fixture.context.accessibility = false
        fixture.controller.retry()
        XCTAssertEqual(fixture.context.accessibilityRequests, 1)
        fixture.context.accessibility = true
        fixture.controller.retry()
        XCTAssertEqual(fixture.monitor.starts, 1)
        XCTAssertFalse(fixture.controller.isRunning)
        fixture.monitor.status(.ready)
        XCTAssertTrue(fixture.controller.isRunning)
        fixture.controller.setEnabled(false)
        XCTAssertFalse(fixture.controller.isEnabled)
    }

    @MainActor
    func testDelayedHitAfterUpReleasesLeaseAndNeverBegins() async throws {
        let fixture = DragFixture(); fixture.start()
        await fixture.reader.blockCapture()
        fixture.send(.leftDown, gesture: 1)
        try await spin { await fixture.reader.captureBlocked }
        fixture.send(.leftUp, gesture: 1)
        await fixture.reader.resumeCapture()
        try await spin { fixture.controller.captureRequestCount == 0 }
        XCTAssertFalse(fixture.controller.lifecycleEvents.contains { $0.kind == .began })
        try await spin { await fixture.reader.leaseCount == 0 }
        let leases = await fixture.reader.leaseCount
        XCTAssertEqual(leases, 0)
        XCTAssertEqual(fixture.controller.state, .idle)
        fixture.stop()
    }

    @MainActor
    func testContinuousDownCoalescesCaptureAndIgnoresOldUp() async throws {
        let fixture = DragFixture(); fixture.start()
        await fixture.reader.blockCapture()
        fixture.send(.leftDown, gesture: 1)
        try await spin { await fixture.reader.captureBlocked }
        for gesture in 2 ... 10_001 { fixture.send(.leftDown, gesture: UInt64(gesture)) }
        XCTAssertEqual(fixture.controller.captureRequestCount, 1)
        fixture.send(.leftUp, gesture: 1)
        await fixture.reader.resumeCapture()
        try await spin { fixture.controller.captureRequestCount == 0 }
        let captures = await fixture.reader.captureCount
        XCTAssertEqual(captures, 2)
        if case .candidate = fixture.controller.state {} else { XCTFail("The latest down must survive an old up") }
        fixture.stop()
    }

    @MainActor
    func testFirstMotionBeforeBaselineCancelsRatherThanInventingOriginal() async throws {
        let fixture = DragFixture(); fixture.start()
        await fixture.reader.blockCapture()
        fixture.send(.leftDown, gesture: 1, timestamp: 10)
        try await spin { await fixture.reader.captureBlocked }
        fixture.send(.leftDragged, gesture: 1, timestamp: 20)
        await fixture.reader.setCapturedAt(30)
        await fixture.reader.resumeCapture()
        try await spin { fixture.controller.captureRequestCount == 0 }
        XCTAssertEqual(fixture.controller.state, .idle)
        XCTAssertTrue(fixture.controller.statusMessage.contains("initial frame"))
        XCTAssertFalse(fixture.controller.lifecycleEvents.contains { $0.kind == .began })
        fixture.stop()
    }

    @MainActor
    func testTenThousandMovesKeepOneReadAndOnePendingPoint() async throws {
        let fixture = DragFixture(); fixture.start()
        fixture.send(.leftDown, gesture: 1)
        try await spin { fixture.controller.captureRequestCount == 0 }
        await fixture.reader.blockFrame()
        fixture.send(.leftDragged, gesture: 1, point: CGPoint(x: 10, y: 0))
        try await spin { await fixture.reader.frameBlocked }
        for index in 0 ..< 10_000 { fixture.send(.leftDragged, gesture: 1, point: CGPoint(x: index, y: 0)) }
        XCTAssertEqual(fixture.controller.frameRequestCount, 1)
        XCTAssertEqual(fixture.controller.pendingFrameCount, 1)
        let reads = await fixture.reader.frameCount
        XCTAssertEqual(reads, 1)
        fixture.send(.leftUp, gesture: 1)
        XCTAssertEqual(fixture.controller.pendingFrameCount, 0)
        await fixture.reader.resumeFrame()
        try await spin { fixture.controller.frameRequestCount == 0 }
        XCTAssertEqual(fixture.controller.state, .idle)
        fixture.stop()
    }

    @MainActor
    func testDelayedOldReleaseCannotEraseNextGesture() async throws {
        let fixture = DragFixture(); fixture.start()
        fixture.send(.leftDown, gesture: 1)
        try await spin { fixture.controller.captureRequestCount == 0 }
        await fixture.reader.blockRelease()
        fixture.send(.leftUp, gesture: 1)
        try await spin { await fixture.reader.releaseBlocked }
        fixture.send(.leftDown, gesture: 2)
        try await spin { fixture.controller.captureRequestCount == 0 }
        await fixture.reader.resumeRelease()
        try await spin { !(await fixture.reader.releaseBlocked) }
        if case .candidate = fixture.controller.state {} else { XCTFail("Old release must not clear the next gesture") }
        let leases = await fixture.reader.leaseCount
        XCTAssertEqual(leases, 1)
        XCTAssertTrue(fixture.context.gate)
        fixture.stop()
    }

    @MainActor
    func testOldFrameFailureCannotCancelNextGesture() async throws {
        let fixture = DragFixture(); fixture.start()
        fixture.send(.leftDown, gesture: 1)
        try await spin { fixture.controller.captureRequestCount == 0 }
        await fixture.reader.blockFrame()
        fixture.send(.leftDragged, gesture: 1)
        try await spin { await fixture.reader.frameBlocked }
        fixture.send(.leftDown, gesture: 2)
        try await spin { fixture.controller.captureRequestCount == 0 }
        await fixture.reader.failFrame()
        try await spin { fixture.controller.frameRequestCount == 0 }
        if case .candidate = fixture.controller.state {} else { XCTFail("Stale error cancelled the new gesture") }
        fixture.stop()
    }

    @MainActor
    func testModifiersUpdateStationaryMovingGesture() async throws {
        let fixture = DragFixture(); fixture.start()
        try await fixture.becomeMoving()
        fixture.send(.flagsChanged, gesture: 1, flags: 42)
        let event = try XCTUnwrap(fixture.controller.lifecycleEvents.last)
        XCTAssertEqual(event.kind, .updated)
        XCTAssertEqual(event.flags, 42)
        fixture.send(.leftUp, gesture: 1)
        XCTAssertEqual(fixture.controller.lifecycleEvents.last?.kind, .ended)
        fixture.stop()
    }

    @MainActor
    func testTerminalCausesReleaseAndReturnIdle() async throws {
        for cause in [DragInputKind.escape, .tapDisabled, .overflow] {
            let fixture = DragFixture(); fixture.start()
            try await fixture.becomeMoving()
            fixture.send(cause, gesture: 1)
            try await spin { await fixture.reader.leaseCount == 0 }
            XCTAssertEqual(fixture.controller.state, .idle)
            XCTAssertFalse(fixture.context.gate)
            XCTAssertEqual(fixture.controller.lifecycleEvents.last?.kind, .cancelled)
            if cause != .escape { XCTAssertFalse(fixture.controller.isRunning); XCTAssertGreaterThan(fixture.monitor.stops, 0) }
            fixture.stop()
        }
    }

}

extension DragDetectionTests {
    @MainActor
    func testPermissionFingerprintAndSpaceChangesInvalidatePendingCapture() async throws {
        for cause in 0 ..< 3 {
            let fixture = DragFixture(); fixture.start()
            await fixture.reader.blockCapture()
            fixture.send(.leftDown, gesture: 1)
            try await spin { await fixture.reader.captureBlocked }
            if cause == 0 { fixture.context.accessibility = false; fixture.controller.checkHealth() }
            if cause == 1 { fixture.context.fingerprint = "changed"; fixture.controller.checkHealth() }
            if cause == 2 { fixture.controller.environmentChanged(reason: "Space changed") }
            await fixture.reader.resumeCapture()
            try await spin { fixture.controller.captureRequestCount == 0 }
            XCTAssertEqual(fixture.controller.state, .idle)
            XCTAssertFalse(fixture.controller.lifecycleEvents.contains { $0.kind == .began })
            XCTAssertGreaterThan(fixture.context.invalidations, 0)
            try await spin { await fixture.reader.leaseCount == 0 }
            let leases = await fixture.reader.leaseCount
            XCTAssertEqual(leases, 0)
            fixture.stop()
        }
    }

    @MainActor
    func testQuitCancellationPreservesEnabledIntentAndRejectsOldMonitorCallbacks() async throws {
        let fixture = DragFixture(); fixture.start()
        fixture.send(.leftDown, gesture: 1)
        try await spin { fixture.controller.captureRequestCount == 0 }
        let oldHandler = fixture.monitor.handler
        let oldStatus = fixture.monitor.statusHandler
        fixture.controller.shutdownForQuit()
        XCTAssertTrue(fixture.controller.isEnabled)
        XCTAssertFalse(fixture.controller.isRunning)
        fixture.controller.resumeAfterCancelledQuit()
        fixture.monitor.status(.ready)
        oldStatus?(.failed("old tap"))
        oldHandler?(DragInputEvent(kind: .leftDown, sequence: 99, gesture: 99))
        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertEqual(fixture.controller.state, .idle)
        XCTAssertFalse(fixture.context.gate)
        fixture.stop()
    }

    @MainActor
    func testRetryRequiresButtonsReleasedAndTimeoutRecoveryIsFinite() {
        let fixture = DragFixture(); fixture.start()
        fixture.monitor.status(.interrupted("timeout"))
        XCTAssertEqual(fixture.monitor.starts, 2)
        fixture.monitor.status(.ready)
        fixture.monitor.status(.interrupted("timeout"))
        XCTAssertEqual(fixture.monitor.starts, 2)
        XCTAssertFalse(fixture.controller.isRunning)
        fixture.context.released = false
        fixture.controller.retry()
        XCTAssertEqual(fixture.monitor.starts, 2)
        fixture.context.released = true
        fixture.controller.retry()
        XCTAssertEqual(fixture.monitor.starts, 3)
        fixture.stop()
    }

    @MainActor
    func testHitFailureAndUnverifiedTitlebarRemainIdle() async throws {
        for verified in [true, false] {
            let fixture = DragFixture(); fixture.start()
            await fixture.reader.setHit(verified: verified, fail: verified)
            fixture.send(.leftDown, gesture: 1)
            try await spin { fixture.controller.captureRequestCount == 0 }
            XCTAssertEqual(fixture.controller.state, .idle)
            XCTAssertFalse(fixture.context.gate)
            try await spin { await fixture.reader.leaseCount == 0 }
            let leases = await fixture.reader.leaseCount
            XCTAssertEqual(leases, 0)
            fixture.stop()
        }
    }
}

final class DragPrewarmTests: XCTestCase {
    @MainActor
    func testVerifiedPreDownFrameAllowsDelayedCaptureAfterFirstDrag() async throws {
        let fixture = DragFixture(); fixture.start()
        try await warm(fixture)
        XCTAssertEqual(fixture.controller.prewarmCacheCount, 1)
        await fixture.reader.blockCapture()
        await fixture.reader.setCapturedAt(100_000_100)
        await fixture.reader.setFrame(CGRect(x: 10, y: 0, width: 400, height: 300))
        await fixture.reader.setRevision(1, changedAt: 100_000_050)
        fixture.send(.leftDown, gesture: 1, timestamp: 100_000_010)
        try await spin { await fixture.reader.captureBlocked }
        fixture.send(.leftDragged, gesture: 1, point: CGPoint(x: 10, y: 0), timestamp: 100_000_050)
        await fixture.reader.resumeCapture()
        try await spin { fixture.controller.captureRequestCount == 0 && fixture.controller.frameRequestCount == 0 }
        fixture.send(.leftDragged, gesture: 1, point: CGPoint(x: 10, y: 0), timestamp: 100_000_200)
        try await spin { fixture.controller.frameRequestCount == 0 }
        fixture.send(.leftUp, gesture: 1, timestamp: 100_000_300)
        let events = fixture.controller.lifecycleEvents
        XCTAssertEqual(events.filter { $0.kind == .began }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .ended }.count, 1)
        XCTAssertEqual(events.first { $0.kind == .began }?.frame, CGRect(x: 0, y: 0, width: 400, height: 300))
        try await spin { await fixture.reader.leaseCount == 0 }
        fixture.stop()
    }

    @MainActor
    func testCacheCannotCrossWindowSizeRevisionDisplayOrAge() async throws {
        for invalidation in 0 ..< 5 {
            let fixture = DragFixture(); fixture.start()
            try await warm(fixture)
            if invalidation == 0 { await fixture.reader.switchToken() }
            if invalidation == 1 { await fixture.reader.setFrame(CGRect(x: 0, y: 0, width: 500, height: 300)) }
            if invalidation == 2 { await fixture.reader.setRevision(1, changedAt: 100_000_005) }
            if invalidation == 3 { fixture.context.fingerprint = "different" }
            let down: UInt64 = invalidation == 4 ? 300_000_010 : 100_000_010
            await fixture.reader.blockCapture()
            await fixture.reader.setCapturedAt(down + 100)
            fixture.send(.leftDown, gesture: 1, timestamp: down)
            try await spin { await fixture.reader.captureBlocked }
            fixture.send(.leftDragged, gesture: 1, point: CGPoint(x: 10, y: 0), timestamp: down + 50)
            await fixture.reader.resumeCapture()
            try await spin { fixture.controller.captureRequestCount == 0 }
            XCTAssertEqual(fixture.controller.state, .idle)
            XCTAssertFalse(fixture.controller.lifecycleEvents.contains { $0.kind == .began })
            try await spin { await fixture.reader.leaseCount == 0 }
            fixture.stop()
        }
    }

    @MainActor
    func testPrewarmFloodStaysBoundedAndPostDownHoverResultIsNotBaseline() async throws {
        let fixture = DragFixture(); fixture.start()
        await fixture.reader.blockCapture()
        fixture.send(.mouseMoved, gesture: 0, timestamp: 100_000_001)
        try await spin { await fixture.reader.captureBlocked }
        for index in 1 ... 10_000 { fixture.send(.mouseMoved, gesture: 0, timestamp: 100_000_001 + UInt64(index)) }
        XCTAssertEqual(fixture.controller.captureRequestCount, 1)
        XCTAssertEqual(fixture.controller.pendingHoverCount, 1)
        fixture.send(.leftDown, gesture: 1, timestamp: 100_100_000)
        fixture.send(.leftDragged, gesture: 1, timestamp: 100_100_050)
        await fixture.reader.setCapturedAt(100_100_100)
        await fixture.reader.resumeCapture()
        try await spin { fixture.controller.captureRequestCount == 0 }
        let captures = await fixture.reader.captureCount
        XCTAssertEqual(captures, 2)
        XCTAssertEqual(fixture.controller.state, .idle)
        XCTAssertEqual(fixture.controller.prewarmCacheCount, 0)
        XCTAssertFalse(fixture.controller.lifecycleEvents.contains { $0.kind == .began })
        fixture.stop()
    }

    @MainActor
    func testUnsupportedObserverAndUpBeforeValidationDoNotLeakLease() async throws {
        for unsupported in [true, false] {
            let fixture = DragFixture(); fixture.start()
            await fixture.reader.setNotificationsVerified(!unsupported)
            try await warm(fixture)
            XCTAssertEqual(fixture.controller.prewarmCacheCount, unsupported ? 0 : 1)
            await fixture.reader.blockCapture()
            fixture.send(.leftDown, gesture: 1, timestamp: 100_000_010)
            try await spin { await fixture.reader.captureBlocked }
            fixture.send(.leftUp, gesture: 1, timestamp: 100_000_030)
            await fixture.reader.resumeCapture()
            try await spin { fixture.controller.captureRequestCount == 0 }
            try await spin { await fixture.reader.leaseCount == 0 }
            XCTAssertEqual(fixture.controller.state, .idle)
            XCTAssertFalse(fixture.controller.lifecycleEvents.contains { $0.kind == .began })
            fixture.stop()
        }
    }

    @MainActor
    private func warm(_ fixture: DragFixture) async throws {
        await fixture.reader.setCapturedAt(100_000_002)
        fixture.send(.mouseMoved, gesture: 0, timestamp: 100_000_001)
        try await spin { fixture.controller.captureRequestCount == 0 }
    }
}

extension DragDetectionTests {
    @MainActor
    func testCleanupBackpressureRemainsBoundedAcrossTerminalFlood() async throws {
        let fixture = DragFixture(); fixture.start()
        await fixture.reader.blockRelease()
        fixture.send(.leftDown, gesture: 1)
        try await spin { fixture.controller.captureRequestCount == 0 }
        fixture.send(.leftUp, gesture: 1)
        try await spin { await fixture.reader.releaseBlocked }
        fixture.send(.leftDown, gesture: 2)
        try await spin { fixture.controller.captureRequestCount == 0 }
        fixture.send(.leftUp, gesture: 2)
        for value in 3 ... 10_003 { fixture.send(.leftDown, gesture: UInt64(value)) }
        XCTAssertEqual(fixture.controller.cleanupRequestCount, 2)
        XCTAssertEqual(fixture.controller.captureRequestCount, 0)
        let captures = await fixture.reader.captureCount
        XCTAssertEqual(captures, 2)
        await fixture.reader.resumeRelease()
        try await spin { await fixture.reader.captureCount == 3 && fixture.controller.captureRequestCount == 0 && fixture.controller.cleanupRequestCount == 0 }
        fixture.stop()
    }

    func testFirstDraggedTimestampSurvivesCoalesceAndDrain() {
        var mailbox = DragMailbox()
        mailbox.enqueue(kind: .leftDown, timestamp: 5)
        _ = mailbox.drain()
        mailbox.enqueue(kind: .leftDragged, timestamp: 10)
        mailbox.enqueue(kind: .leftDragged, timestamp: 20)
        let first = mailbox.drain()
        XCTAssertEqual(first.first?.timestamp, 20)
        XCTAssertEqual(first.first?.firstDraggedTimestamp, 10)
        mailbox.enqueue(kind: .flagsChanged, timestamp: 22)
        mailbox.enqueue(kind: .leftDragged, timestamp: 30)
        XCTAssertEqual(mailbox.drain().last?.firstDraggedTimestamp, 10)
    }

    @MainActor
    func testCoalescedMotionBeforeFrameSampleIsNeverOriginalFrame() async throws {
        let fixture = DragFixture(); fixture.start()
        await fixture.reader.blockCapture()
        fixture.send(.leftDown, gesture: 1, timestamp: 5)
        try await spin { await fixture.reader.captureBlocked }
        var mailbox = DragMailbox()
        mailbox.enqueue(kind: .leftDown, timestamp: 5); _ = mailbox.drain()
        mailbox.enqueue(kind: .leftDragged, timestamp: 10)
        mailbox.enqueue(kind: .leftDragged, timestamp: 20)
        let motion = try XCTUnwrap(mailbox.drain().first)
        fixture.monitor.handler?(DragInputEvent(kind: .leftDragged, timestamp: motion.timestamp, sequence: 2,
                                                gesture: 1, firstDraggedTimestamp: motion.firstDraggedTimestamp))
        await fixture.reader.setCapturedAt(15)
        await fixture.reader.resumeCapture()
        try await spin { fixture.controller.captureRequestCount == 0 }
        XCTAssertEqual(fixture.controller.state, .idle)
        XCTAssertFalse(fixture.controller.lifecycleEvents.contains { $0.kind == .began })
        fixture.stop()
    }
}

extension DragPrewarmTests {
    @MainActor
    func testEarlierMoveOrResizeCannotBeHiddenByLaterNativeMoveRevision() async throws {
        for resized in [true, false] {
            let fixture = DragFixture(); fixture.start()
            try await warm(fixture)
            await fixture.reader.setRevision(1, changedAt: 100_000_005, resized: resized)
            await fixture.reader.setRevision(2, changedAt: 100_000_050)
            await fixture.reader.setCapturedAt(100_000_100)
            await fixture.reader.setFrame(CGRect(x: 10, y: 0, width: 400, height: 300))
            fixture.send(.leftDown, gesture: 1, timestamp: 100_000_010)
            try await spin { fixture.controller.captureRequestCount == 0 }
            XCTAssertEqual(fixture.controller.state, .idle)
            XCTAssertFalse(fixture.controller.lifecycleEvents.contains { $0.kind == .began })
            try await spin { await fixture.reader.leaseCount == 0 }
            fixture.stop()
        }
    }
}

extension DragPrewarmTests {
    @MainActor
    func testMovedWindowCanValidateOnceAtLatestPointerAfterOriginalPointHitsContent() async throws {
        let fixture = DragFixture(); fixture.start()
        try await warm(fixture)
        await fixture.reader.setHitResponses([false, true])
        await fixture.reader.blockCapture()
        await fixture.reader.setCapturedAt(100_000_100)
        await fixture.reader.setFrame(CGRect(x: 10, y: 0, width: 400, height: 300))
        fixture.send(.leftDown, gesture: 1, timestamp: 100_000_010)
        try await spin { await fixture.reader.captureBlocked }
        fixture.send(.leftDragged, gesture: 1, point: CGPoint(x: 10, y: 0), timestamp: 100_000_050)
        await fixture.reader.resumeCapture()
        try await spin { fixture.controller.captureRequestCount == 0 && fixture.controller.frameRequestCount == 0 }
        fixture.send(.leftDragged, gesture: 1, point: CGPoint(x: 10, y: 0), timestamp: 100_000_200)
        try await spin { fixture.controller.frameRequestCount == 0 }
        fixture.send(.leftUp, gesture: 1, timestamp: 100_000_300)
        XCTAssertEqual(fixture.controller.lifecycleEvents.filter { $0.kind == .began }.count, 1)
        XCTAssertEqual(fixture.controller.lifecycleEvents.filter { $0.kind == .ended }.count, 1)
        let captures = await fixture.reader.captureCount
        XCTAssertEqual(captures, 3)
        try await spin { await fixture.reader.leaseCount == 0 }
        fixture.stop()
    }
}

extension DragDetectionTests {
    @MainActor
    func testEndedConsumerCanBeginNextGestureWithoutOldTerminalClearingIt() async throws {
        let fixture = DragFixture(); fixture.start()
        try await fixture.becomeMoving()
        fixture.controller.onLifecycle = { event in
            if event.kind == .ended { fixture.send(.leftDown, gesture: 2) }
        }
        fixture.send(.leftUp, gesture: 1)
        try await spin { fixture.controller.captureRequestCount == 0 && fixture.controller.cleanupRequestCount == 0 }
        if case .candidate = fixture.controller.state {} else { XCTFail("The terminal callback's next gesture was cleared") }
        XCTAssertTrue(fixture.context.gate)
        let leases = await fixture.reader.leaseCount
        XCTAssertEqual(leases, 1)
        fixture.controller.onLifecycle = nil
        fixture.stop()
    }
}
