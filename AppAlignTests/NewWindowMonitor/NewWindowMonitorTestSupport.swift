import XCTest

@MainActor
struct RuntimeDestroyOwnerFixture {
    let directory: URL
    let store: PersistentStoreCoordinator
    let layout: LayoutController
    let display: Display
    let persistedLayout: PersistedLayout
    let runtime: AccessibilityWindowRuntime

    static func make() async throws -> RuntimeDestroyOwnerFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignDestroyOwner-\(UUID().uuidString)")
        let store = PersistentStoreCoordinator(directory: directory)
        let persistedLayout = PersistentStoreCoordinator.defaultLayout()
        try await store.saveLayouts([persistedLayout])
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: PersistentDisplayID(uuid: UUID()),
                              sessionID: UUID(), name: "Destroy", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800), isPrimary: true, backingScaleFactor: 1)
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)),
                                      storeCoordinator: store)
        await layout.loadPersistentState()
        let effects = RetryProbePlacementEffects(failFirstPosition: false)
        let mover = WindowMover(messagingTimeout: 0.5, retryLimit: 1, effects: effects)
        let runtime = AccessibilityWindowRuntime(focusedWindowValidator: { _ in },
                                                 accessibilityTrustedProvider: { true },
                                                 mover: mover, historyMover: mover,
                                                 settableAttributeProvider: { _, _ in true },
                                                 historyObserverProvider: { _, _, _, _ in true })
        layout.appHistoryCoordinator.releaseRuntimeLease = { token, lease in
            Task { await runtime.releaseHistoryLease(token, lease: lease) }
        }
        await runtime.setHistoryWindowDestroyedHandler { token, _ in
            Task { @MainActor in layout.appWindowDestroyed(token) }
        }
        return RuntimeDestroyOwnerFixture(directory: directory, store: store, layout: layout,
                                          display: display, persistedLayout: persistedLayout, runtime: runtime)
    }

    func token(pid: pid_t) async throws -> RuntimeWindowToken {
        let application = AXUIElementCreateApplication(pid)
        let window = AXWindow(applicationElement: application, element: application, pid: pid)
        return try await runtime.token(for: window)
    }

    func place(_ token: RuntimeWindowToken, zoneID: Int, frame: CGRect) async throws -> PlacementController {
        let snapshot = layout.displayProvider.snapshot
        let manualLease = ManualWindowLeaseID()
        let retained = await runtime.retainManualLease(token, lease: manualLease)
        XCTAssertTrue(retained)
        let capture = ManualWindowCapture(token: token, lease: manualLease,
                                          originalFrame: CGRect(x: 10, y: 20, width: 300, height: 200))
        let lease = layout.reserveAppPlacement(token: token, bundleID: "com.example.Owner", display: display,
                                               layout: persistedLayout)
        let acquired = await layout.acquireAppPlacement(lease, using: runtime)
        let controller = PlacementController(
            displayProvider: layout.displayProvider,
            refreshDisplayConfiguration: { snapshot },
            dependencies: PlacementControllerDependencies(isAccessibilityTrusted: { true }),
            manualRuntime: runtime, initialManualCapture: capture,
            initialManualDisplayFingerprint: snapshot.fingerprint
        )
        controller.onSuccessfulPlacement = { _, context in
            layout.acceptSuccessfulAppPlacement(context.historyLease, zoneIDs: context.zoneIDs)
        }
        let context = PlacementHistoryContext(display: display, layout: persistedLayout, zoneIDs: [zoneID],
                                              historyLease: acquired, expectedToken: token)
        try await controller.placeCapturedWindowAsync(in: frame, displayFingerprint: snapshot.fingerprint,
                                                      historyContext: context)
        XCTAssertTrue(controller.canRestore, "A successful placement must keep its captured original frame for Restore.")
        layout.releaseAppPlacement(acquired)
        return controller
    }
}

@MainActor
struct AutoRestoreFixture {
    let directory: URL
    let store: PersistentStoreCoordinator
    let layout: LayoutController
    let display: Display
    let persistedLayout: PersistedLayout
    let runtime: AccessibilityWindowRuntime
    let mover: BlockingPlacementMover

    static func make(mismatchedFrame: Bool, blockSetter: Bool, spaceProvider: SpaceProvider? = nil) async throws -> AutoRestoreFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignAutoRestore-\(UUID().uuidString)")
        let store = PersistentStoreCoordinator(directory: directory)
        let persistedLayout = PersistentStoreCoordinator.defaultLayout()
        try await store.saveLayouts([persistedLayout])
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: PersistentDisplayID(uuid: UUID()),
                              sessionID: UUID(), name: "Auto", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800), isPrimary: true, backingScaleFactor: 1)
        if let spaceProvider {
            _ = await refreshSpaceProvider(spaceProvider, displays: [display.persistentID!.uuid])
            if !spaceProvider.snapshot(for: display.persistentID!.uuid).recordsHistory {
                _ = try await store.load()
                let key = AppZoneHistoryKey(bundleID: "com.example.Auto", displayUUID: display.persistentID!.uuid,
                                            spaceScope: .common, layoutID: persistedLayout.id)
                try await store.upsertAppZoneHistory(AppZoneHistoryRecord(key: key, zoneIDs: [0], revision: 1),
                                                     expectedLayout: persistedLayout)
            }
        }
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)),
                                      spaceProvider: spaceProvider ?? SpaceProvider(), storeCoordinator: store)
        await layout.loadPersistentState()
        var settings = layout.appHistorySettings
        settings.monitorNewWindows = true
        settings.restoreNewWindows = true
        layout.appHistorySettings = settings
        let key = AppZoneHistoryKey(bundleID: "com.example.Auto", displayUUID: display.persistentID!.uuid,
                                    spaceScope: .common, layoutID: persistedLayout.id)
        if layout.spaceSnapshot(for: display).recordsHistory {
            layout.recordAppZoneHistory(key: key, expectedLayout: persistedLayout, zoneIDs: [0])
            let historyFlushed = await layout.flush()
            XCTAssertTrue(historyFlushed)
        }
        let mover = BlockingPlacementMover(shouldBlock: blockSetter, mismatchedFrame: mismatchedFrame)
        let runtime = AccessibilityWindowRuntime(
            focusedWindowValidator: { _ in },
            accessibilityTrustedProvider: { true },
            mover: mover,
            historyMover: mover,
            settableAttributeProvider: { _, _ in true },
            historyObserverProvider: { _, _, _, _ in true }
        )
        layout.appHistoryCoordinator.releaseRuntimeLease = { token, lease in
            Task { await runtime.releaseHistoryLease(token, lease: lease) }
        }
        return AutoRestoreFixture(directory: directory, store: store, layout: layout, display: display,
                                  persistedLayout: persistedLayout, runtime: runtime, mover: mover)
    }
}

actor BlockingAutoObservationRuntime: AutomaticWindowOperating {
    private let candidates: [pid_t: WindowObservationCandidate]
    private var observationCount = 0
    private var released = false
    private var entryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var observations: [CheckedContinuation<Void, Never>] = []

    init(tokens: [RuntimeWindowToken]) {
        candidates = Dictionary(uniqueKeysWithValues: tokens.map { token in
            (token.pid, WindowObservationCandidate(token: token, readiness: .temporarilyUnavailable))
        })
    }

    func waitUntilObserved(count: Int) async {
        if observationCount >= count { return }
        await withCheckedContinuation { entryWaiters.append((count, $0)) }
    }

    func releaseObservations() {
        released = true
        let pending = observations
        observations.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func processGenerationForMonitoring(_ pid: pid_t, launchDate: Date) async -> UUID {
        candidates[pid]?.token.processGeneration ?? UUID()
    }

    func observeWindowCreation(applicationPID pid: pid_t, processGeneration generation: UUID,
                               epoch: UInt64, signal: @escaping @Sendable (pid_t, UUID, UInt64) -> Void) async -> Bool { true }
    func stopWindowObservation(applicationPID pid: pid_t, processGeneration generation: UUID) async {}

    func observedWindows(applicationPID pid: pid_t, processGeneration generation: UUID,
                         ownPID: pid_t, deadline: UInt64) async throws -> WindowObservationResult {
        observationCount += 1
        let ready = entryWaiters.filter { observationCount >= $0.0 }
        entryWaiters.removeAll { observationCount >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
        if !released { await withCheckedContinuation { observations.append($0) } }
        let candidate = candidates[pid].map {
            WindowObservationCandidate(token: $0.token, readiness: .temporarilyUnavailable)
        }
        return WindowObservationResult(candidates: candidate.map { [$0] } ?? [], isComplete: false)
    }

    func retainMonitorSeenLease(_ token: RuntimeWindowToken, lease: RuntimeMonitorSeenLeaseID) async -> Bool { false }
    func releaseMonitorSeenLease(_ token: RuntimeWindowToken, lease: RuntimeMonitorSeenLeaseID) async {}
    func discardProcess(_ pid: pid_t, expectedGeneration generation: UUID) async -> [RuntimeWindowToken] { [] }
    func retainHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID) async -> Bool { false }
    func releaseHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID) async {}
    func moveHistoryWindow(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID, to frame: CGRect,
                           ticket: PlacementCommitTicket,
                           preflight: @MainActor @Sendable () async -> Bool) async throws -> CGRect {
        throw WindowManagementError.operationFailed
    }
}

final class BlockingPlacementMover: WindowPlacementOperating, @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private let shouldBlock: Bool
    private let mismatchedFrame: Bool
    private var frames: [CGRect] = []

    init(shouldBlock: Bool, mismatchedFrame: Bool) {
        self.shouldBlock = shouldBlock
        self.mismatchedFrame = mismatchedFrame
    }

    var returnedCount: Int { lock.withLock { frames.count } }
    var returnedFrames: [CGRect] { lock.withLock { frames } }
    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { self.entered.wait(); continuation.resume() }
        }
    }
    func releaseSetter() { gate.signal() }

    func movePlacement(_ window: AXWindow, to requestedFrame: CGRect,
                       ticket: PlacementCommitTicket) throws -> PlacementResult {
        guard ticket.state == .writing else { throw WindowManagementError.displayConfigurationChanged }
        if shouldBlock {
            entered.signal()
            gate.wait()
            guard ticket.mayContinueWrite(now: DispatchTime.now().uptimeNanoseconds) else {
                throw WindowManagementError.displayConfigurationChanged
            }
        }
        let actual = mismatchedFrame ? requestedFrame.offsetBy(dx: 80, dy: 0) : requestedFrame
        lock.withLock { frames.append(actual) }
        return PlacementResult(requestedFrame: requestedFrame, actualFrame: actual)
    }

    func moveDrag(_ window: AXWindow, to requestedFrame: CGRect, ticket: DragCommitTicket) throws -> PlacementResult {
        try movePlacement(window, to: requestedFrame, ticket: ticket)
    }
}

final class RetryProbePlacementEffects: WindowPlacementEffects, @unchecked Sendable {
    private let lock = NSLock()
    private let failFirstPosition: Bool
    private var didFailPosition = false
    private var origin = CGPoint.zero
    private var size = CGSize.zero
    private var positions = 0
    private var deadlines: [UInt64?] = []

    init(failFirstPosition: Bool) { self.failFirstPosition = failFirstPosition }
    var positionAttempts: Int { lock.withLock { positions } }
    var observedDeadlines: [UInt64?] { lock.withLock { deadlines } }

    func setPosition(_ point: CGPoint, on window: AXWindow) throws {
        try lock.withLock {
            positions += 1
            deadlines.append(window.operationDeadline)
            if failFirstPosition, !didFailPosition {
                didFailPosition = true
                throw WindowManagementError.writeFailed(attribute: "AXPosition", code: -1)
            }
            origin = point
        }
    }

    func setSize(_ value: CGSize, on window: AXWindow) throws { lock.withLock { deadlines.append(window.operationDeadline); size = value } }
    func readFrame(on window: AXWindow) throws -> CGRect {
        lock.withLock { deadlines.append(window.operationDeadline); return CGRect(origin: origin, size: size) }
    }
}

final class OperationDeadlineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64?] = []
    private var timeouts: [Float] = []
    func record(_ deadline: UInt64?, timeout: Float? = nil) {
        lock.withLock {
            values.append(deadline)
            if deadline != nil, let timeout { timeouts.append(timeout) }
        }
    }
    var deadlines: [UInt64?] { lock.withLock { values } }
    var operationTimeouts: [Float] { lock.withLock { timeouts } }
}

final class RuntimeDestroyEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RuntimeWindowToken] = []
    func record(_ token: RuntimeWindowToken) { lock.withLock { values.append(token) } }
    var tokens: [RuntimeWindowToken] { lock.withLock { values } }
}

final class RecordingAutoRestoreClock: AutoRestoreClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 0
    private var sleeps: [UInt64] = []

    func now() -> UInt64 { lock.withLock { current } }
    func sleep(nanoseconds: UInt64) async throws {
        lock.withLock {
            sleeps.append(nanoseconds)
            current &+= nanoseconds
        }
    }
    func advance(nanoseconds: UInt64) { lock.withLock { current &+= nanoseconds } }
    var sleepDurations: [UInt64] { lock.withLock { sleeps } }
}

actor RetryReadinessRuntime: AutomaticWindowOperating {
    private let token: RuntimeWindowToken
    private let clock: RecordingAutoRestoreClock
    private var times: [UInt64] = []

    init(token: RuntimeWindowToken, clock: RecordingAutoRestoreClock) {
        self.token = token
        self.clock = clock
    }

    var observationTimes: [UInt64] { times }
    var observationCount: Int { times.count }

    func processGenerationForMonitoring(_ pid: pid_t, launchDate: Date) async -> UUID { token.processGeneration }
    func observeWindowCreation(applicationPID pid: pid_t, processGeneration generation: UUID,
                               epoch: UInt64, signal: @escaping @Sendable (pid_t, UUID, UInt64) -> Void) async -> Bool { true }
    func stopWindowObservation(applicationPID pid: pid_t, processGeneration generation: UUID) async {}
    func observedWindows(applicationPID pid: pid_t, processGeneration generation: UUID,
                         ownPID: pid_t, deadline: UInt64) async throws -> WindowObservationResult {
        times.append(clock.now())
        clock.advance(nanoseconds: 50_000_000)
        return WindowObservationResult(candidates: [WindowObservationCandidate(token: token, readiness: .temporarilyUnavailable)],
                                      isComplete: true)
    }
    func discardProcess(_ pid: pid_t, expectedGeneration generation: UUID) async -> [RuntimeWindowToken] { [] }
    func retainMonitorSeenLease(_ token: RuntimeWindowToken, lease: RuntimeMonitorSeenLeaseID) async -> Bool { true }
    func releaseMonitorSeenLease(_ token: RuntimeWindowToken, lease: RuntimeMonitorSeenLeaseID) async {}
    func retainHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID) async -> Bool { true }
    func retainHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID,
                            deadline: UInt64) async -> Bool { clock.now() < deadline }
    func releaseHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID) async {}
    func moveHistoryWindow(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID, to frame: CGRect,
                           ticket: PlacementCommitTicket,
                           preflight: @MainActor @Sendable () async -> Bool) async throws -> CGRect {
        throw WindowManagementError.operationFailed
    }
}

@MainActor
final class MonitorProcessProvider: NewWindowProcessProviding {
    private var applications: [pid_t: MonitoredApplication]

    init(applications: [MonitoredApplication]) { self.applications = Dictionary(uniqueKeysWithValues: applications.map { ($0.pid, $0) }) }
    func runningApplications() -> [MonitoredApplication] { Array(applications.values) }
    func application(processID: pid_t) -> MonitoredApplication? { applications[processID] }
    func set(_ application: MonitoredApplication) { applications[application.pid] = application }
}

private struct MonitorCreationSignal {
    let generation: UUID
    let epoch: UInt64
    let callback: @Sendable (pid_t, UUID, UInt64) -> Void
}

actor MonitorRuntime: NewWindowMonitorRuntime {
    private var generations: [pid_t: UUID] = [:]
    private var launchDates: [pid_t: Date] = [:]
    private var snapshots: [pid_t: [WindowObservationCandidate]] = [:]
    private var observations: [pid_t: UUID] = [:]
    private var creationSignals: [pid_t: MonitorCreationSignal] = [:]
    private var snapshotReadCount = 0
    private var pauseSnapshot = false
    private var pausedSnapshot: CheckedContinuation<Void, Never>?
    private var snapshotArrival: CheckedContinuation<Void, Never>?
    private var pauseObservationStop = false
    private var pausedObservationStop: CheckedContinuation<Void, Never>?
    private var observationStopArrival: CheckedContinuation<Void, Never>?
    private var registrationCount = 0
    private var seenLeases: [RuntimeWindowToken: Set<RuntimeMonitorSeenLeaseID>] = [:]
    private var pauseSeenRetain = false
    private var rejectNextSeenRetain = false
    private var pausedSeenRetain: CheckedContinuation<Void, Never>?
    private var seenRetainArrival: CheckedContinuation<Void, Never>?
    private var completedSeenRetains = 0
    private var retainedSeenLeases: [RuntimeWindowToken: Set<RuntimeMonitorSeenLeaseID>] = [:]
    private var releasedSeenLeases: Set<RuntimeMonitorSeenLeaseID> = []

    func generation(for pid: pid_t) -> UUID {
        if let value = generations[pid] { return value }
        let value = UUID()
        generations[pid] = value
        return value
    }

    func setSnapshot(_ candidates: [WindowObservationCandidate], pid: pid_t) { snapshots[pid] = candidates }
    func observationCount() -> Int { observations.count }
    func observationRegistrationCount() -> Int { registrationCount }
    func snapshotCount() -> Int { snapshotReadCount }
    func pauseNextSnapshot() { pauseSnapshot = true }
    func waitForPausedSnapshot() async {
        if !pauseSnapshot { return }
        await withCheckedContinuation { snapshotArrival = $0 }
    }
    func releasePausedSnapshot() {
        pausedSnapshot?.resume()
        pausedSnapshot = nil
    }

    func pauseNextObservationStop() { pauseObservationStop = true }
    func waitForPausedObservationStop() async {
        if !pauseObservationStop { return }
        await withCheckedContinuation { observationStopArrival = $0 }
    }
    func releasePausedObservationStop() {
        pausedObservationStop?.resume()
        pausedObservationStop = nil
    }

    func pauseNextSeenRetention() { pauseSeenRetain = true }
    func rejectNextSeenRetention() { rejectNextSeenRetain = true }
    func waitForPausedSeenRetention() async {
        if !pauseSeenRetain { return }
        await withCheckedContinuation { seenRetainArrival = $0 }
    }
    func releasePausedSeenRetention() async {
        pausedSeenRetain?.resume()
        pausedSeenRetain = nil
    }
    func seenLeaseTokenCount() -> Int { seenLeases.count }
    func completedSeenRetainCount() -> Int { completedSeenRetains }
    func retainedAndReleasedSeenLeaseCount() -> Int {
        guard retainedSeenLeases.count == 0 else { return 0 }
        return releasedSeenLeases.count
    }

    func emitCreation(pid: pid_t) {
        guard let signal = creationSignals[pid] else { return }
        signal.callback(pid, signal.generation, signal.epoch)
    }
    func processGenerationForMonitoring(_ pid: pid_t, launchDate: Date) async -> UUID {
        if launchDates[pid].map({ $0 != launchDate }) == true {
            generations[pid] = UUID()
        }
        launchDates[pid] = launchDate
        return generation(for: pid)
    }

    func observeWindowCreation(applicationPID pid: pid_t, processGeneration generation: UUID,
                               epoch: UInt64, signal: @escaping @Sendable (pid_t, UUID, UInt64) -> Void) async -> Bool {
        observations[pid] = generation
        registrationCount += 1
        creationSignals[pid] = MonitorCreationSignal(generation: generation, epoch: epoch, callback: signal)
        return true
    }

    func stopWindowObservation(applicationPID pid: pid_t, processGeneration generation: UUID) async {
        if pauseObservationStop {
            pauseObservationStop = false
            observationStopArrival?.resume()
            observationStopArrival = nil
            await withCheckedContinuation { pausedObservationStop = $0 }
        }
        if observations[pid] == generation {
            observations.removeValue(forKey: pid)
            creationSignals.removeValue(forKey: pid)
        }
    }

    func observedWindows(applicationPID pid: pid_t, processGeneration generation: UUID,
                         ownPID: pid_t, deadline: UInt64) async throws -> WindowObservationResult {
        snapshotReadCount += 1
        let snapshot = snapshots[pid] ?? []
        if pauseSnapshot {
            pauseSnapshot = false
            snapshotArrival?.resume()
            snapshotArrival = nil
            await withCheckedContinuation { pausedSnapshot = $0 }
        }
        let candidates = snapshot.map { candidate in
            WindowObservationCandidate(token: RuntimeWindowToken(id: candidate.token.id, pid: pid,
                                                                  processGeneration: generation),
                                       readiness: candidate.readiness)
        }
        return WindowObservationResult(candidates: candidates, isComplete: true)
    }

    func discardProcess(_ pid: pid_t, expectedGeneration generation: UUID) async -> [RuntimeWindowToken] {
        guard generations[pid] == generation else { return [] }
        generations.removeValue(forKey: pid)
        launchDates.removeValue(forKey: pid)
        observations.removeValue(forKey: pid)
        return []
    }

    func retainMonitorSeenLease(_ token: RuntimeWindowToken, lease: RuntimeMonitorSeenLeaseID) async -> Bool {
        if pauseSeenRetain {
            pauseSeenRetain = false
            seenRetainArrival?.resume()
            seenRetainArrival = nil
            await withCheckedContinuation { pausedSeenRetain = $0 }
        }
        completedSeenRetains += 1
        if rejectNextSeenRetain {
            rejectNextSeenRetain = false
            return false
        }
        if seenLeases[token]?.contains(lease) == true { return true }
        guard seenLeases[token] != nil || seenLeases.count < 64 else { return false }
        seenLeases[token, default: []].insert(lease)
        retainedSeenLeases[token, default: []].insert(lease)
        return true
    }

    func seenLeaseCount() -> Int { seenLeases.values.reduce(0) { $0 + $1.count } }

    func releaseMonitorSeenLease(_ token: RuntimeWindowToken, lease: RuntimeMonitorSeenLeaseID) async {
        seenLeases[token]?.remove(lease)
        if seenLeases[token]?.isEmpty == true { seenLeases.removeValue(forKey: token) }
        if retainedSeenLeases[token]?.contains(lease) == true {
            retainedSeenLeases[token]?.remove(lease)
            if retainedSeenLeases[token]?.isEmpty == true { retainedSeenLeases.removeValue(forKey: token) }
            releasedSeenLeases.insert(lease)
        }
    }

    func retainHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID) async -> Bool { true }
    func releaseHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID) async {}
}
