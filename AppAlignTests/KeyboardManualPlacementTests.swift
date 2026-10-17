import XCTest
import ApplicationServices

extension KeyboardSnapControllerTests {
    @MainActor
    func testCrossDisplayKeyboardPlacementRecordsTargetLayoutAndZoneOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignCrossDisplayHistory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceUUID = UUID()
        let targetUUID = UUID()
        let source = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: PersistentDisplayID(uuid: sourceUUID),
                             sessionID: UUID(), name: "Source", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                             workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800), isPrimary: true, backingScaleFactor: 1)
        let target = Display(runtimeID: RuntimeDisplayID(rawValue: 2), persistentID: PersistentDisplayID(uuid: targetUUID),
                             sessionID: UUID(), name: "Target", frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
                             workArea: CGRect(x: 1_000, y: 0, width: 1_000, height: 800), isPrimary: false, backingScaleFactor: 1)
        let sourceLayoutID = UUID()
        let targetLayoutID = UUID()
        let sourceLayout = PersistedLayout(id: sourceLayoutID,
                                           definition: .grid(GridLayout(id: LayoutID(rawValue: sourceLayoutID), rows: 1, columns: 2, rowPercentages: [10_000],
                                                                        columnPercentages: [5_000, 5_000], cellChildMap: [[7, 8]])),
                                           spacing: 0, template: .columns, zoneCount: 2)
        let targetLayout = PersistedLayout(id: targetLayoutID,
                                           definition: .grid(GridLayout(id: LayoutID(rawValue: targetLayoutID), rows: 1, columns: 1, rowPercentages: [10_000],
                                                                        columnPercentages: [10_000], cellChildMap: [[9]])),
                                           spacing: 0, template: .columns, zoneCount: 1)
        let store = PersistentStoreCoordinator(directory: directory)
        try await store.saveLayoutAndAssignments(
            [PersistentStoreCoordinator.defaultLayout(), sourceLayout, targetLayout],
            [PersistedAssignment(displayUUID: sourceUUID, spaceScope: .common, layoutID: sourceLayout.id),
             PersistedAssignment(displayUUID: targetUUID, spaceScope: .common, layoutID: targetLayout.id)]
        )
        let snapshot = DisplaySnapshot(displays: [source, target], primaryFrame: source.frame)
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: snapshot), storeCoordinator: store)
        await layout.loadPersistentState()
        let sourceKey = AppZoneHistoryKey(bundleID: "com.example.CrossDisplay", displayUUID: sourceUUID,
                                          spaceScope: .common, layoutID: sourceLayout.id)
        let targetKey = AppZoneHistoryKey(bundleID: "com.example.CrossDisplay", displayUUID: targetUUID,
                                          spaceScope: .common, layoutID: targetLayout.id)
        layout.recordAppZoneHistory(key: sourceKey, expectedLayout: sourceLayout, zoneIDs: [8])
        let sourceHistoryFlushed = await layout.flush()
        XCTAssertTrue(sourceHistoryFlushed)

        let pid = getpid()
        let backend = FakeKeyboardWindowBackend(frame: CGRect(x: 500, y: 0, width: 500, height: 800), pid: pid)
        let environment = KeyboardEnvironment(frontmostPID: { pid }, isAccessibilityTrusted: { true }, ownPID: -1,
                                              bundleIdentifier: { _ in "com.example.CrossDisplay" })
        let controller = KeyboardSnapController(layoutController: layout, backend: backend, environment: environment)
        var settings = layout.keyboardSettings
        settings.isEnabled = true
        settings.mode = .zoneOrder
        settings.cyclesAtEdges = false
        layout.updateKeyboardSettings(settings)
        controller.handle(.direction(.right))
        for _ in 0 ..< 100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.isBusy)
        let targetHistoryFlushed = await layout.flush()
        XCTAssertTrue(targetHistoryFlushed)
        let sourceRecord = try XCTUnwrap(layout.appZoneHistory[sourceKey])
        let targetRecord = try XCTUnwrap(layout.appZoneHistory[targetKey], "history keys: \(Array(layout.appZoneHistory.keys))")
        XCTAssertEqual(sourceRecord.zoneIDs, [8])
        XCTAssertEqual(sourceRecord.revision, 1, "The source display history must not be rewritten by the target placement.")
        XCTAssertEqual(targetRecord.zoneIDs, [9], "The actual keyboard navigation target's sparse ZoneID is persisted.")
        XCTAssertEqual(targetRecord.revision, 2)
        let retainedLeaseCount = await backend.retainedHistoryLeaseCount()
        let windowToken = await backend.windowToken()
        XCTAssertEqual(retainedLeaseCount, 1)
        XCTAssertTrue(layout.appHistoryCoordinator.isAssigned(token: windowToken))
    }

    @MainActor
    func testManualPlacementAndRestoreRejectInvalidationAfterReadback() async throws {
        let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: nil, sessionID: UUID(),
                              name: "Test", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 780), isPrimary: true,
                              backingScaleFactor: 1)
        let snapshot = DisplaySnapshot(displays: [display], primaryFrame: display.frame)
        let placed = CGRect(x: 10, y: 10, width: 480, height: 380)
        let token = RuntimeWindowToken(id: UUID(), pid: 200)
        let capture = ManualWindowCapture(token: token, lease: ManualWindowLeaseID(), originalFrame: frame)
        let trustedDependencies = PlacementControllerDependencies(
            isAccessibilityTrusted: { true }
        )

        do {
            let validity = PlacementValidity()
            let runtime = ManualWindowTestRuntime(capture: capture, initialFrame: frame)
            let controller = PlacementController(
                displayProvider: DisplayProvider(snapshot: snapshot),
                validity: validity,
                refreshDisplayConfiguration: { snapshot },
                dependencies: trustedDependencies,
                manualRuntime: runtime,
                initialManualCapture: capture,
                initialManualDisplayFingerprint: snapshot.fingerprint
            )
            try await controller.placeCapturedWindowAsync(in: placed, displayFingerprint: snapshot.fingerprint,
                                                          historyContext: nil)
            let placementStates = await runtime.getTicketStates()
            XCTAssertEqual(placementStates, [.writing], "The manual setter must run only after its ticket enters the writing state.")
            XCTAssertEqual(controller.actualFrame, placed)
            XCTAssertTrue(controller.statusMessage.contains("Placed and verified"))
            XCTAssertTrue(controller.canRestore)
            await controller.restoreCapturedWindow()
            let restoreStates = await runtime.getTicketStates()
            XCTAssertEqual(restoreStates, [.writing, .writing], "Manual Restore must use the same ticket write boundary.")
            XCTAssertEqual(controller.actualFrame, frame)
            XCTAssertTrue(controller.statusMessage.contains("Restored and verified"))
            XCTAssertTrue(controller.canRestore)
        }

        for restoring in [false, true] {
            let validity = PlacementValidity()
            let runtime = ManualWindowTestRuntime(capture: capture, initialFrame: frame, afterMove: {
                _ = validity.invalidateForConfigurationChange()
            })
            let controller = PlacementController(
                displayProvider: DisplayProvider(snapshot: snapshot),
                validity: validity,
                refreshDisplayConfiguration: { snapshot },
                dependencies: trustedDependencies,
                manualRuntime: runtime,
                initialManualCapture: capture,
                initialManualDisplayFingerprint: snapshot.fingerprint
            )
            if restoring {
                await controller.restoreCapturedWindow()
            } else {
                do {
                    try await controller.placeCapturedWindowAsync(in: placed, displayFingerprint: snapshot.fingerprint,
                                                                  historyContext: nil)
                    XCTFail("A configuration change after readback must reject completion.")
                } catch {}
            }
            XCTAssertFalse(controller.statusMessage.contains("verified"))
            XCTAssertEqual(controller.actualFrame, restoring ? frame : placed)
            XCTAssertTrue(controller.hasCapturedWindow)
            XCTAssertTrue(controller.canRestore, "A rejected completion must preserve the original Restore target.")
        }
    }

    @MainActor
    func testStaleManualReadbackCannotOverwriteANewerCapture() async throws {
        let original = CGRect(x: 100, y: 100, width: 300, height: 200)
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: nil, sessionID: UUID(),
                              name: "Test", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 780), isPrimary: true,
                              backingScaleFactor: 1)
        let snapshot = DisplaySnapshot(displays: [display], primaryFrame: display.frame)
        let first = ManualWindowCapture(token: RuntimeWindowToken(id: UUID(), pid: 200),
                                        lease: ManualWindowLeaseID(), originalFrame: original)
        let secondFrame = CGRect(x: 450, y: 220, width: 420, height: 310)
        let second = ManualWindowCapture(token: RuntimeWindowToken(id: UUID(), pid: 201),
                                         lease: ManualWindowLeaseID(), originalFrame: secondFrame)
        let validity = PlacementValidity()
        let runtime = ManualWindowTestRuntime(capture: first, initialFrame: original, nextCaptures: [second], afterMove: {
            _ = validity.invalidateForConfigurationChange()
        })
        let controller = PlacementController(displayProvider: DisplayProvider(snapshot: snapshot), validity: validity,
                                             refreshDisplayConfiguration: { snapshot },
                                             dependencies: PlacementControllerDependencies(isAccessibilityTrusted: { true }),
                                             manualRuntime: runtime, initialManualCapture: first,
                                             initialManualDisplayFingerprint: snapshot.fingerprint)
        await runtime.blockNextReadback()
        let placement = Task { try? await controller.placeCapturedWindowAsync(
            in: CGRect(x: 20, y: 30, width: 500, height: 400),
            displayFingerprint: snapshot.fingerprint, historyContext: nil
        ) }
        await runtime.waitForBlockedReadback()

        let newCapture = controller.startManualCapture(applicationPID: second.token.pid, displaySnapshot: snapshot)
        await newCapture.value
        XCTAssertEqual(controller.capturedRuntimeToken, second.token)
        XCTAssertEqual(controller.actualFrame, secondFrame)
        XCTAssertTrue(controller.statusMessage.contains("Captured the focused external window"))

        await runtime.completeBlockedReadback()
        await placement.value
        XCTAssertEqual(controller.capturedRuntimeToken, second.token)
        XCTAssertEqual(controller.actualFrame, secondFrame, "The delayed readback from the previous token must not overwrite the new capture frame.")
        XCTAssertTrue(controller.statusMessage.contains("Captured the focused external window"),
                       "A stale placement failure must not overwrite the newer capture status.")
    }

    @MainActor
    func testFirstMovePreservesOriginalAndRestoreSuccessConsumesSession() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        var settings = fixture.layout.keyboardSettings
        settings.isEnabled = true
        fixture.layout.updateKeyboardSettings(settings)

        fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        let firstIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(firstIdle)
        let firstWriteCount = await fixture.backend.writeCount()
        XCTAssertEqual(firstWriteCount, 1)
        XCTAssertTrue(fixture.controller.hasRestoreTarget)
        fixture.controller.handle(.zone(ZoneID(rawValue: 1)))
        let secondIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(secondIdle)
        let secondWriteCount = await fixture.backend.writeCount()
        XCTAssertEqual(secondWriteCount, 2)
        let placedFrame = await fixture.backend.currentFrame()
        XCTAssertEqual(placedFrame, fixture.layout.appliedLayoutSnapshot(for: fixture.originalFrame)?.zones.first(where: { $0.id.rawValue == 1 })?.frame)

        fixture.controller.handle(.restore)
        let restoreIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(restoreIdle)
        let totalWriteCount = await fixture.backend.writeCount()
        XCTAssertEqual(totalWriteCount, 3)
        XCTAssertFalse(fixture.controller.hasRestoreTarget)
        let restoredFrame = await fixture.backend.currentFrame()
        XCTAssertEqual(restoredFrame, fixture.originalFrame)
    }

    @MainActor
    func testFailedRestoreKeepsTheOriginalFrameForRetry() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        var settings = fixture.layout.keyboardSettings
        settings.isEnabled = true
        fixture.layout.updateKeyboardSettings(settings)

        fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        let placementIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(placementIdle)
        await fixture.backend.failNextRestore()
        fixture.controller.handle(.restore)
        let failedRestoreIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(failedRestoreIdle)
        XCTAssertTrue(fixture.controller.hasRestoreTarget)
        XCTAssertTrue(fixture.controller.statusMessage.contains("still saved"))

        fixture.controller.handle(.restore)
        let restoreIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(restoreIdle)
        XCTAssertFalse(fixture.controller.hasRestoreTarget)
        let restoredFrame = await fixture.backend.currentFrame()
        XCTAssertEqual(restoredFrame, fixture.originalFrame)
    }

    @MainActor
    func testUnchangedDisplayConfigurationRestoresExactFrameOutsideWorkArea() async throws {
        let original = CGRect(x: -40, y: -20, width: 300, height: 200)
        let fixture = try await Fixture.make(originalFrame: original,
                                             workArea: CGRect(x: 0, y: 30, width: 1_000, height: 750))
        defer { fixture.remove() }
        var settings = fixture.layout.keyboardSettings
        settings.isEnabled = true
        fixture.layout.updateKeyboardSettings(settings)

        fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        let placementIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(placementIdle)
        fixture.controller.handle(.restore)
        let restoreIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(restoreIdle)
        let restoredFrame = await fixture.backend.currentFrame()
        XCTAssertEqual(restoredFrame, original)
        XCTAssertFalse(fixture.controller.hasRestoreTarget)
    }

    @MainActor
    func testConfigurationChangeTranslatesRestoreAnchorAndDisconnectKeepsIt() async throws {
        let original = CGRect(x: 600, y: 400, width: 300, height: 200)
        let id = PersistentDisplayID(uuid: UUID())
        let first = makeDisplay(id: id, frame: CGRect(x: 0, y: 0, width: 1_000, height: 800))
        let translated = makeDisplay(id: id, frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800))
        let fixture = try await Fixture.make(originalFrame: original,
                                             snapshots: Array(repeating: snapshot(first), count: 5) + [snapshot(translated)])
        defer { fixture.remove() }
        var settings = fixture.layout.keyboardSettings
        settings.isEnabled = true
        fixture.layout.updateKeyboardSettings(settings)
        fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        let placementIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(placementIdle)
        fixture.controller.handle(.restore)
        let restoreIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(restoreIdle)
        let frameAfterMove = await fixture.backend.currentFrame()
        XCTAssertEqual(frameAfterMove, CGRect(x: 1_600, y: 400, width: 300, height: 200))
        XCTAssertFalse(fixture.controller.hasRestoreTarget)

        let disconnectedFixture = try await Fixture.make(originalFrame: original,
                                                         snapshots: Array(repeating: snapshot(first), count: 5)
                                                            + [DisplaySnapshot(displays: [], primaryFrame: .zero)])
        defer { disconnectedFixture.remove() }
        var disconnectedSettings = disconnectedFixture.layout.keyboardSettings
        disconnectedSettings.isEnabled = true
        disconnectedFixture.layout.updateKeyboardSettings(disconnectedSettings)
        disconnectedFixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        let disconnectedPlacementIdle = await disconnectedFixture.waitUntilIdle()
        XCTAssertTrue(disconnectedPlacementIdle)
        disconnectedFixture.controller.handle(.restore)
        let disconnectedRestoreIdle = await disconnectedFixture.waitUntilIdle()
        XCTAssertTrue(disconnectedRestoreIdle)
        XCTAssertTrue(disconnectedFixture.controller.hasRestoreTarget)
        let writes = await disconnectedFixture.backend.writeCount()
        XCTAssertEqual(writes, 1)
    }

    @MainActor
    struct Fixture {
        let layout: LayoutController
        let backend: FakeKeyboardWindowBackend
        let controller: KeyboardSnapController
        let originalFrame = CGRect(x: 600, y: 400, width: 300, height: 200)
        let directory: URL

        static func make(originalFrame: CGRect = CGRect(x: 600, y: 400, width: 300, height: 200),
                         workArea: CGRect = CGRect(x: 0, y: 0, width: 1_000, height: 800),
                         snapshots: [DisplaySnapshot]? = nil) async throws -> Fixture {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let uuid = UUID()
            let display = Display(
                runtimeID: RuntimeDisplayID(rawValue: 1),
                persistentID: PersistentDisplayID(uuid: uuid),
                sessionID: UUID(), name: "Test", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                workArea: workArea, isPrimary: true, backingScaleFactor: 1
            )
            let provider = snapshots.map { DisplayProvider(snapshots: $0) }
                ?? DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame))
            let layout = LayoutController(
                displayProvider: provider,
                storeCoordinator: PersistentStoreCoordinator(directory: directory)
            )
            await layout.loadPersistentState()
            let frame = originalFrame
            let backend = FakeKeyboardWindowBackend(frame: frame)
            let environment = KeyboardEnvironment(frontmostPID: { 200 }, isAccessibilityTrusted: { true }, ownPID: 100)
            let controller = KeyboardSnapController(layoutController: layout, backend: backend, environment: environment)
            return Fixture(layout: layout, backend: backend, controller: controller, directory: directory)
        }

        func waitUntilIdle() async -> Bool {
            for _ in 0 ..< 100 where controller.isBusy {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if controller.isBusy { return false }
            return await layout.flush()
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private func snapshot(_ display: Display) -> DisplaySnapshot {
        DisplaySnapshot(displays: [display], primaryFrame: display.frame)
    }

    private func makeDisplay(id: PersistentDisplayID, frame: CGRect) -> Display {
        Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: id, sessionID: UUID(), name: "Test",
                frame: frame, workArea: frame, isPrimary: true, backingScaleFactor: 1)
    }
}

enum ManualHistoryWaitChange {
    case quickLayout
    case recapture
}

actor ManualWindowTestRuntime: ManualWindowOperating {
    private let capture: ManualWindowCapture
    private let nextCaptures: [ManualWindowCapture]
    private var frame: CGRect
    private let afterMove: @Sendable () -> Void
    private var releasedLeases = Set<ManualWindowLeaseID>()
    private var ticketStates: [PlacementValidity.State] = []
    private var nextCaptureIndex = 0
    private var shouldBlockReadback = false
    private var blockedReadback: CheckedContinuation<Void, Never>?
    private var readbackStarted: CheckedContinuation<Void, Never>?
    private var pauseHistoryRetain = false
    private var historyRetainBarrier: CheckedContinuation<Void, Never>?
    private var historyRetainStarted: CheckedContinuation<Void, Never>?
    private var retainedHistoryLeases = Set<RuntimeHistoryLeaseID>()

    init(capture: ManualWindowCapture, initialFrame: CGRect, nextCaptures: [ManualWindowCapture] = [],
         afterMove: @escaping @Sendable () -> Void = {}) {
        self.capture = capture
        self.nextCaptures = nextCaptures
        frame = initialFrame
        self.afterMove = afterMove
    }

    func captureManualWindow(applicationPID: pid_t, ownPID: pid_t) async throws -> ManualWindowCapture {
        if nextCaptureIndex < nextCaptures.count {
            let next = nextCaptures[nextCaptureIndex]
            nextCaptureIndex += 1
            frame = next.originalFrame
            return next
        }
        return capture
    }

    func moveManualWindow(_ token: RuntimeWindowToken, lease: ManualWindowLeaseID, to frame: CGRect,
                          ticket: PlacementCommitTicket,
                          preflight: @MainActor @Sendable () async -> Bool) async throws -> CGRect {
        guard token == capture.token, lease == capture.lease,
              !releasedLeases.contains(lease), await preflight(),
              ticket.beginWrite(now: DispatchTime.now().uptimeNanoseconds) else {
            throw WindowManagementError.displayConfigurationChanged
        }
        ticketStates.append(ticket.state)
        self.frame = frame
        afterMove()
        return frame
    }

    func readManualWindowFrame(_ token: RuntimeWindowToken, lease: ManualWindowLeaseID) async throws -> CGRect {
        guard token == capture.token, lease == capture.lease,
              !releasedLeases.contains(lease) else { throw WindowManagementError.noCapturedWindow }
        let staleFrame = frame
        guard shouldBlockReadback else { return staleFrame }
        shouldBlockReadback = false
        await withCheckedContinuation { continuation in
            blockedReadback = continuation
            readbackStarted?.resume()
            readbackStarted = nil
        }
        return staleFrame
    }

    func releaseManualLease(_ token: RuntimeWindowToken, lease: ManualWindowLeaseID) async {
        guard token == capture.token else { return }
        releasedLeases.insert(lease)
    }

    func retainHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID) async -> Bool {
        if pauseHistoryRetain {
            pauseHistoryRetain = false
            historyRetainStarted?.resume()
            historyRetainStarted = nil
            await withCheckedContinuation { historyRetainBarrier = $0 }
        }
        retainedHistoryLeases.insert(lease)
        return true
    }
    func releaseHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID) async {
        retainedHistoryLeases.remove(lease)
    }
    func getTicketStates() -> [PlacementValidity.State] { ticketStates }
    func blockNextReadback() { shouldBlockReadback = true }
    func blockNextHistoryRetain() { pauseHistoryRetain = true }
    func waitForHistoryRetain() async {
        if historyRetainBarrier != nil { return }
        await withCheckedContinuation { historyRetainStarted = $0 }
    }
    func releaseHistoryRetain() { historyRetainBarrier?.resume(); historyRetainBarrier = nil }
    func historyLeaseCountValue() -> Int { retainedHistoryLeases.count }
    func currentFrameValue() -> CGRect { frame }
    func waitForBlockedReadback() async {
        if blockedReadback != nil { return }
        await withCheckedContinuation { readbackStarted = $0 }
    }
    func completeBlockedReadback() {
        blockedReadback?.resume()
        blockedReadback = nil
    }
}

actor FakeKeyboardWindowBackend: KeyboardWindowOperating {
    private let token: RuntimeWindowToken
    private var frame: CGRect
    private var writes = 0
    private var failRestore = false
    private var historyLeases = Set<RuntimeHistoryLeaseID>()

    init(frame: CGRect, pid: pid_t = 200) {
        self.frame = frame
        token = RuntimeWindowToken(id: UUID(), pid: pid)
    }

    func focusedWindow(applicationPID: pid_t, ownPID: pid_t) async throws -> RuntimeWindowSnapshot {
        RuntimeWindowSnapshot(token: token, frame: frame)
    }

    func retain(_ token: RuntimeWindowToken) async {}

    func retainHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID) async -> Bool {
        guard token == self.token else { return false }
        historyLeases.insert(lease)
        return true
    }

    func releaseHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID) async {
        guard token == self.token else { return }
        historyLeases.remove(lease)
    }

    func move(_ token: RuntimeWindowToken, to frame: CGRect, ticket: PlacementCommitTicket, preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect {
        guard await preflight(), ticket.beginWrite(now: DispatchTime.now().uptimeNanoseconds) else { throw WindowManagementError.displayConfigurationChanged }
        self.frame = frame
        writes += 1
        return frame
    }

    func restore(_ token: RuntimeWindowToken, to frame: CGRect, ticket: PlacementCommitTicket, preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect {
        guard await preflight(), ticket.beginWrite(now: DispatchTime.now().uptimeNanoseconds) else { throw WindowManagementError.displayConfigurationChanged }
        if failRestore {
            failRestore = false
            throw WindowManagementError.noCapturedWindow
        }
        self.frame = frame
        writes += 1
        return frame
    }

    func discard(_ token: RuntimeWindowToken) async {}
    func shutdown() async {}
    func currentFrame() -> CGRect { frame }
    func writeCount() -> Int { writes }
    func retainedHistoryLeaseCount() -> Int { historyLeases.count }
    func windowToken() -> RuntimeWindowToken { token }
    func failNextRestore() { failRestore = true }
}
