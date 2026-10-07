import Foundation
import XCTest

@MainActor
func spin(_ condition: () async -> Bool) async throws {
    for _ in 0 ..< 10_000 {
        if await condition() { return }
        await Task.yield()
    }
    throw DragTestError.timeout
}

enum DragTestError: Error { case timeout, unavailable }

@MainActor
final class DragContext {
    var input = true
    var accessibility = true
    var released = true
    var fingerprint = "display-1"
    var inputRequests = 0
    var accessibilityRequests = 0
    var gate = false
    var invalidations = 0
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
            inputGranted: { context.input }, accessibilityGranted: { context.accessibility }, requestInput: { context.inputRequests += 1 },
            requestAccessibility: { context.accessibilityRequests += 1 }, buttonsReleased: { context.released },
            displayFingerprint: { context.fingerprint }, now: { 100 }), ownPID: 1, installsObservers: false)
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
        try await spin { controller.captureRequestCount == 0 }
        await reader.setFrame(CGRect(x: 10, y: 0, width: 400, height: 300))
        for _ in 0 ..< 2 {
            send(.leftDragged, gesture: 1, point: CGPoint(x: 10, y: 0))
            try await spin { controller.frameRequestCount == 0 }
        }
        XCTAssertTrue(controller.lifecycleEvents.contains { $0.kind == .began })
    }
}

actor FakeDragReader: DragWindowReading {
    private var token = RuntimeWindowToken(id: UUID(), pid: 2)
    private var leases = Set<DragLeaseID>()
    private var currentFrame = CGRect(x: 0, y: 0, width: 400, height: 300)
    private var capturedAt: UInt64 = 1
    private var verified = true
    private var notificationsVerified = true
    private var revision: UInt64 = 0
    private var changedAt: UInt64 = 0
    private var resized = false
    private var revisionChanges: [WindowRevisionChange] = []
    private var hitFails = false
    private var hitResponses: [Bool] = []
    private var frameFails = false
    private var pauseCapture = false
    private var pauseFrame = false
    private var pauseRelease = false
    private var captureBarrier: CheckedContinuation<Void, Never>?
    private var frameBarrier: CheckedContinuation<Void, Never>?
    private var releaseBarrier: CheckedContinuation<Void, Never>?
    private(set) var captureCount = 0
    private(set) var frameCount = 0
    var captureBlocked: Bool { captureBarrier != nil }
    var frameBlocked: Bool { frameBarrier != nil }
    var releaseBlocked: Bool { releaseBarrier != nil }
    var leaseCount: Int { leases.count }
    func blockCapture() { pauseCapture = true }
    func blockFrame() { pauseFrame = true }
    func blockRelease() { pauseRelease = true }
    func resumeCapture() { captureBarrier?.resume(); captureBarrier = nil }
    func resumeFrame() { frameBarrier?.resume(); frameBarrier = nil }
    func resumeRelease() { releaseBarrier?.resume(); releaseBarrier = nil }
    func setFrame(_ frame: CGRect) { currentFrame = frame }
    func switchToken() { token = RuntimeWindowToken(id: UUID(), pid: 2) }
    func setRevision(_ revision: UInt64, changedAt: UInt64, resized: Bool = false) {
        self.revision = revision; self.changedAt = changedAt; self.resized = resized
        revisionChanges.append(WindowRevisionChange(revision: revision, timestamp: changedAt, kind: resized ? .resized : .moved))
    }
    func setNotificationsVerified(_ value: Bool) { notificationsVerified = value }
    func setCapturedAt(_ time: UInt64) { capturedAt = time }
    func setHitResponses(_ values: [Bool]) { hitResponses = values }
    func setHit(verified: Bool, fail: Bool) { self.verified = verified; hitFails = fail }
    func failFrame() { frameFails = true; resumeFrame() }
    func isWriteInProgress() async -> Bool { false }
    func window(at point: CGPoint, ownPID: pid_t, downTimestamp: UInt64) async throws -> DragWindowSnapshot {
        captureCount += 1
        if pauseCapture { pauseCapture = false; await withCheckedContinuation { captureBarrier = $0 } }
        if hitFails { throw DragTestError.unavailable }
        let verifiedHit = hitResponses.isEmpty ? verified : hitResponses.removeFirst()
        let lease = DragLeaseID(rawValue: UUID()); leases.insert(lease)
        return DragWindowSnapshot(token: token, lease: lease, frame: currentFrame, hitRole: "AXTitleBar",
                                  ancestorRoles: ["AXTitleBar", "AXWindow"], hitInTitleBar: verifiedHit, capturedAt: capturedAt,
                                  hitRegion: CGRect(x: -6, y: -6, width: 12, height: 12), revision: revision, lastChangedAt: changedAt,
                                  changeWasResize: resized, notificationsVerified: notificationsVerified, revisionChanges: revisionChanges)
    }
    func frame(for token: RuntimeWindowToken, lease: DragLeaseID) async throws -> CGRect {
        frameCount += 1
        if pauseFrame { pauseFrame = false; await withCheckedContinuation { frameBarrier = $0 } }
        guard leases.contains(lease), !frameFails else { throw DragTestError.unavailable }
        return currentFrame
    }
    func releaseDragLease(_ lease: DragLeaseID) async {
        if pauseRelease { pauseRelease = false; await withCheckedContinuation { releaseBarrier = $0 } }
        leases.remove(lease)
    }
}
