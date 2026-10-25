import Foundation
import XCTest

@MainActor
func spin(_ condition: () async -> Bool) async throws {
    for _ in 0 ..< 2_000 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw DragTestError.timeout
}

enum DragTestError: Error { case timeout, unavailable }

@MainActor
final class DragContext {
    var accessibility = true
    var released = true
    var fingerprint = "display-1"
    var accessibilityRequests = 0
    var gate = false
    var invalidations = 0
    var downWindow: DownWindowBaseline? = DownWindowBaseline(
        pid: 2, frame: CGRect(x: 0, y: 0, width: 400, height: 300), windowID: 42
    )
    var windowFrame: CGRect? = CGRect(x: 0, y: 0, width: 400, height: 300)
}

@MainActor
final class FakeDragMonitor: DragInputMonitoring {
    var starts = 0
    var stops = 0
    var handler: (@MainActor @Sendable (DragInputEvent) -> Void)?
    var statusHandler: (@MainActor @Sendable (DragMonitorStatus) -> Void)?
    func start(onEvent: @escaping @MainActor @Sendable (DragInputEvent) -> Void, onStatus: @escaping @MainActor @Sendable (DragMonitorStatus) -> Void) {
        starts += 1; handler = onEvent; statusHandler = onStatus
    }
    func stop() { stops += 1 }
    func status(_ value: DragMonitorStatus) { statusHandler?(value) }
}

@MainActor
final class DragFixture {
    let context = DragContext()
    let reader = FakeDragReader()
    let monitor = FakeDragMonitor()
    let controller: DragDetectionController
    var sequence: UInt64 = 0

    init() {
        let context = context
        controller = DragDetectionController(reader: reader, monitor: monitor, environment: DragEnvironment(
            accessibilityGranted: { context.accessibility }, requestAccessibility: { context.accessibilityRequests += 1 },
            buttonsReleased: { context.released },
            displayFingerprint: { context.fingerprint }, now: { 100 },
            downWindow: { _, _ in context.downWindow },
            windowFrame: { id, pid in
                guard context.downWindow?.windowID == id, context.downWindow?.pid == pid else { return nil }
                return context.windowFrame
            }), ownPID: 1, installsObservers: false)
        controller.dragGateChanged = { context.gate = $0 }
        controller.invalidateKeyboard = { context.invalidations += 1 }
    }
    func start() { controller.setEnabled(true); monitor.status(.ready) }
    func stop() { controller.setEnabled(false) }
    func send(_ kind: DragInputKind, gesture: UInt64, point: CGPoint = .zero, timestamp: UInt64 = 100, flags: UInt64 = 0) {
        sequence += 1
        monitor.handler?(DragInputEvent(kind: kind, location: point, flags: flags, timestamp: timestamp, sequence: sequence, gesture: gesture))
    }
    func becomeMoving() async throws {
        send(.leftDown, gesture: 1)
        let moved = CGRect(x: 10, y: 0, width: 400, height: 300)
        context.windowFrame = moved
        await reader.setFrame(moved)
        send(.leftDragged, gesture: 1, point: CGPoint(x: 10, y: 0))
        XCTAssertTrue(controller.lifecycleEvents.contains { $0.kind == .began })
    }
}

actor FakeDragReader: DragWindowReading, DragCommitOperating, KeyboardWindowOperating {
    private var token = RuntimeWindowToken(id: UUID(), pid: 2)
    private var focusedToken: RuntimeWindowToken?
    private var leases = Set<DragLeaseID>()
    private var historyLeases = Set<RuntimeHistoryLeaseID>()
    private var pauseHistoryRetain = false
    private var historyRetainBarrier: CheckedContinuation<Void, Never>?
    private var historyRetainArrival: CheckedContinuation<Void, Never>?
    private var currentFrame = CGRect(x: 0, y: 0, width: 400, height: 300)
    private var ownership = RuntimeWindowOwnership()
    private var pauseCommit = false
    private var commitBarrier: CheckedContinuation<Void, Never>?
    private(set) var commitCount = 0
    private var pauseCapture = false
    private var captureBarrier: CheckedContinuation<Void, Never>?
    private(set) var captureCount = 0
    var captureBlocked: Bool { captureBarrier != nil }
    var historyRetainBlocked: Bool { historyRetainBarrier != nil }
    var historyLeaseCount: Int { historyLeases.count }
    var commitBlocked: Bool { commitBarrier != nil }
    var leaseCount: Int { leases.count }
    func blockCapture() { pauseCapture = true }
    func blockHistoryRetain() { pauseHistoryRetain = true }
    func waitForHistoryRetain() async {
        if !pauseHistoryRetain { return }
        await withCheckedContinuation { historyRetainArrival = $0 }
    }
    func releaseHistoryRetain() { historyRetainBarrier?.resume(); historyRetainBarrier = nil }
    func resumeCapture() { captureBarrier?.resume(); captureBarrier = nil }
    func blockCommit() { pauseCommit = true }
    func resumeCommit() { commitBarrier?.resume(); commitBarrier = nil }
    var ownerSnapshot: RuntimeWindowOwnership { ownership }
    func setFrame(_ frame: CGRect) { currentFrame = frame }
    func focusDifferentWindow() { focusedToken = RuntimeWindowToken(id: UUID(), pid: 3) }
    func retainHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID) async -> Bool {
        if pauseHistoryRetain {
            pauseHistoryRetain = false
            historyRetainArrival?.resume()
            historyRetainArrival = nil
            await withCheckedContinuation { historyRetainBarrier = $0 }
        }
        historyLeases.insert(lease)
        return true
    }
    func releaseHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID) async {
        historyLeases.remove(lease)
    }
    func tokenValue() -> RuntimeWindowToken { token }
    func currentFrameValue() -> CGRect { currentFrame }
    func retainFakeLease(_ lease: DragLeaseID) { leases.insert(lease); ownership.retainDrag(lease) }
    func focusedWindow(applicationPID: pid_t, ownPID: pid_t) -> RuntimeWindowSnapshot {
        RuntimeWindowSnapshot(token: focusedToken ?? token, frame: currentFrame)
    }
    func retain(_ token: RuntimeWindowToken) { guard self.token == token else { return }; ownership.retainKeyboard() }
    func move(_ token: RuntimeWindowToken, to frame: CGRect, ticket: PlacementCommitTicket, preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect {
        guard self.token == token, await preflight(),
              ticket.beginWrite(now: DispatchTime.now().uptimeNanoseconds) else { throw DragTestError.unavailable }
        currentFrame = frame
        ownership.retainKeyboard()
        return frame
    }
    func restore(_ token: RuntimeWindowToken, to frame: CGRect, ticket: PlacementCommitTicket, preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect {
        guard self.token == token, await preflight(),
              ticket.beginWrite(now: DispatchTime.now().uptimeNanoseconds) else { throw DragTestError.unavailable }
        currentFrame = frame
        ownership.retainKeyboard()
        return frame
    }
    func discard(_ token: RuntimeWindowToken) { if self.token == token { ownership.discardKeyboard() } }
    func shutdown() {}
    func discardProcess(_ pid: pid_t) { if token.pid == pid { ownership.discardKeyboard() } }
    func window(at point: CGPoint, ownPID: pid_t) async throws -> DragWindowSnapshot {
        captureCount += 1
        if pauseCapture { pauseCapture = false; await withCheckedContinuation { captureBarrier = $0 } }
        let lease = DragLeaseID(rawValue: UUID())
        leases.insert(lease)
        ownership.retainDrag(lease)
        return DragWindowSnapshot(token: token, lease: lease, frame: currentFrame)
    }
    func releaseDragLease(_ lease: DragLeaseID) async {
        leases.remove(lease)
        ownership.releaseDrag(lease)
    }

    func handoffDragLease(token: RuntimeWindowToken, sourceLease: DragLeaseID, commitID: DragCommitID,
                          ticket: DragCommitTicket) async -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard self.token == token, leases.contains(sourceLease), ticket.state == .pending,
              now < ticket.startDeadline, now < ticket.totalDeadline,
              ownership.handoffDrag(sourceLease, to: commitID) else { return false }
        leases.remove(sourceLease)
        return true
    }

    func commitDrag(_ offer: DragCommitOffer,
                    preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect {
        guard await preflight(), ownership.dragCommits.contains(offer.id) else { throw DragTestError.unavailable }
        if pauseCommit { pauseCommit = false; await withCheckedContinuation { commitBarrier = $0 } }
        guard ownership.dragCommits.contains(offer.id),
              offer.ticket.beginWrite(now: DispatchTime.now().uptimeNanoseconds) else { throw DragTestError.unavailable }
        currentFrame = offer.targetFrame
        commitCount += 1
        return currentFrame
    }

    func releaseDragCommit(token: RuntimeWindowToken, commitID: DragCommitID) async {
        guard self.token == token else { return }
        ownership.releaseDragCommit(commitID)
    }
}
