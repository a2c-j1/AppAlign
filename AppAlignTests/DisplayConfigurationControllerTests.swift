import AppKit
import CoreGraphics
import XCTest

@MainActor
final class DisplayConfigurationControllerTests: XCTestCase {
    func testRegistrationFailureRemainsVisibleAndNotificationFallbackWorks() async throws {
        let fixture = makeFixture(registrationResult: .failure)
        fixture.controller.start()
        await waitForInitialPublication(fixture)
        XCTAssertTrue(fixture.controller.monitoringDiagnostics.contains {
            $0.contains("callback registration failed")
        })
        let closed = expectation(description: "AppKit observer invalidates after CG registration failure")
        let opened = expectation(description: "AppKit observer republishes after CG registration failure")
        fixture.effects.gateExpectations[true] = closed
        fixture.effects.gateExpectations[false] = opened
        fixture.appKit.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await fulfillment(of: [closed, opened], timeout: 2)
        XCTAssertTrue(fixture.validity.isAccepting)
        fixture.controller.dispose()
    }

    func testCGBeginAndNotificationDeliveryKeepGateClosedUntilCompletionAndRestoreABA() async throws {
        let fixture = makeFixture()
        fixture.controller.start()
        await waitForInitialPublication(fixture)
        let oldTicket = try XCTUnwrap(fixture.validity.reserve(startDeadline: .max, totalDeadline: .max))
        let oldEpoch = fixture.controller.callbackEpochForTesting
        try await completeConfigurationTransaction(fixture, oldTicket: oldTicket)
        try await publishAAfterB(fixture)
        try await verifySleepWake(fixture)
        verifyStaleObserverAndCancelQuit(fixture, epoch: oldEpoch)
    }

    func testSleepThenDisplayAndCGCompletionBeforeDeliveryStaysClosedUntilWake() async throws {
        let fixture = makeFixture()
        fixture.sampled.snapshot = fixture.snapshotA
        fixture.controller.start()
        await waitForInitialPublication(fixture)
        var permissionPollingStates: [Bool] = []
        fixture.controller.historyPermissionPollingSuspendedChanged = { permissionPollingStates.append($0) }
        let pointer = try XCTUnwrap(fixture.registeredPointer.pointer)
        let asleep = expectation(description: "sleep remains pending after display notifications")
        fixture.effects.gateExpectations[true] = asleep

        // Posting from this MainActor turn queues delivery Tasks behind these
        // synchronous callbacks, reproducing a notification burst before the
        // monitor can handle any of them.
        fixture.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        fixture.appKit.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        issue9DisplayReconfigured(0, [], pointer)
        fixture.controller.pollForTesting()
        XCTAssertFalse(fixture.validity.isAccepting)
        XCTAssertEqual(fixture.provider.snapshot, fixture.snapshotA)
        XCTAssertNil(fixture.layout.appliedLayoutSnapshot(for: fixture.snapshotA.displays[0].frame))
        XCTAssertNil(fixture.layout.appliedDragLayoutSnapshot(at: CGPoint(x: 10, y: 10)))

        await fulfillment(of: [asleep], timeout: 2)
        XCTAssertEqual(permissionPollingStates, [true], "Sleep stops the history permission timer synchronously.")
        XCTAssertFalse(fixture.validity.isAccepting)
        XCTAssertEqual(fixture.provider.snapshot, fixture.snapshotA)
        XCTAssertNil(fixture.layout.appliedLayoutSnapshot(for: fixture.snapshotA.displays[0].frame))
        XCTAssertNil(fixture.layout.appliedDragLayoutSnapshot(at: CGPoint(x: 10, y: 10)))

        fixture.sampled.snapshot = fixture.snapshotB
        let awake = expectation(description: "wake publishes the latest sampled display")
        fixture.effects.gateExpectations[false] = awake
        fixture.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        await fulfillment(of: [awake], timeout: 2)
        XCTAssertEqual(permissionPollingStates, [true, false], "Wake resumes lifecycle through the current settings gate.")
        XCTAssertEqual(fixture.provider.snapshot, fixture.snapshotB)
        XCTAssertTrue(fixture.validity.isAccepting)
        fixture.controller.dispose()
    }

    func testWakeThenDisplayAndCGCompletionBeforeDeliveryPublishesOnlyLatestSnapshot() async throws {
        let fixture = makeFixture()
        fixture.sampled.snapshot = fixture.snapshotA
        fixture.controller.start()
        await waitForInitialPublication(fixture)
        let asleep = expectation(description: "sleep delivery closes admission")
        fixture.effects.gateExpectations[true] = asleep
        fixture.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        await fulfillment(of: [asleep], timeout: 2)
        XCTAssertFalse(fixture.validity.isAccepting)

        fixture.sampled.snapshot = fixture.snapshotB
        let awake = expectation(description: "wake plus queued display events publishes latest state")
        fixture.effects.gateExpectations[false] = awake
        fixture.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        fixture.appKit.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        issue9DisplayReconfigured(0, [], try XCTUnwrap(fixture.registeredPointer.pointer))
        fixture.controller.pollForTesting()

        XCTAssertFalse(fixture.validity.isAccepting,
                       "Polling while wake/display deliveries are queued must not reopen admission early.")
        XCTAssertEqual(fixture.provider.snapshot, fixture.snapshotA)
        await fulfillment(of: [awake], timeout: 2)
        XCTAssertEqual(fixture.provider.snapshot, fixture.snapshotB)
        XCTAssertTrue(fixture.validity.isAccepting)
        fixture.controller.dispose()
    }

    func testSpaceCallbackInvalidatesTicketSynchronouslyAndMainActorPublishesAfterward() async throws {
        let fixture = makeFixture()
        fixture.sampled.snapshot = fixture.snapshotA
        fixture.controller.start()
        await waitForInitialPublication(fixture)
        let ticket = try XCTUnwrap(fixture.validity.reserve(startDeadline: .max, totalDeadline: .max))
        let gateClosed = expectation(description: "Space delivery closes configuration gate")
        fixture.effects.gateExpectations[true] = gateClosed

        fixture.workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(ticket.state, .invalidated, "The public callback must invalidate the ticket before its MainActor task runs.")
        await fulfillment(of: [gateClosed], timeout: 2)
        fixture.sampled.snapshot = fixture.snapshotB
        let gateOpened = expectation(description: "sampled Space state is published")
        fixture.effects.gateExpectations[false] = gateOpened
        fixture.workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await fulfillment(of: [gateOpened], timeout: 2)
        XCTAssertEqual(fixture.provider.snapshot, fixture.snapshotB)
        fixture.controller.dispose()
    }
}

@MainActor
extension DisplayConfigurationControllerTests {
    func testHeldSpaceReadsKeepMainActorResponsiveAndOnlyLatestAbaRequestPublishes() async throws {
        let callStarted = expectation(description: "initial A backend read starts")
        let observer = BackendCallObserver(expectations: [1: callStarted])
        let backend = ControlledSpaceBackend(observer: observer)
        let fixture = makeFixture(spaceBackend: backend)
        fixture.sampled.snapshot = fixture.snapshotA
        fixture.controller.start()
        await fulfillment(of: [callStarted], timeout: 2)
        XCTAssertTrue(fixture.effects.gatePending)
        XCTAssertFalse(fixture.validity.isAccepting)

        fixture.controller.pollForTesting()
        XCTAssertTrue(fixture.effects.gatePending, "A held backend read must not block MainActor work.")

        fixture.sampled.snapshot = fixture.snapshotB
        let bDelivered = expectation(description: "B request is accepted on MainActor")
        fixture.effects.environmentChangeExpectations[fixture.effects.environmentChangeCount + 2] = bDelivered
        fixture.workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await fulfillment(of: [bDelivered], timeout: 2)
        fixture.sampled.snapshot = fixture.snapshotA
        let aDelivered = expectation(description: "latest A request replaces B while retaining the published A display")
        fixture.effects.environmentChangeExpectations[fixture.effects.environmentChangeCount + 2] = aDelivered
        fixture.workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await fulfillment(of: [aDelivered], timeout: 2)
        let callsWhileHeld = await backend.callCount
        XCTAssertEqual(callsWhileHeld, 1, "Only one backend call may run while the newest request waits.")

        let secondCallStarted = expectation(description: "latest A starts after old read returns")
        observer.expect(2, fulfills: secondCallStarted)
        await backend.fail(call: 1)
        await fulfillment(of: [secondCallStarted], timeout: 2)
        XCTAssertEqual(fixture.spaceProvider.mode, .commonOnly, "The old candidate must not change the published Space cache.")
        let opened = expectation(description: "latest A snapshot publishes after the held request returns")
        fixture.effects.gateExpectations[false] = opened
        await backend.complete(call: 2, id: "current-A")
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(fixture.provider.snapshot, fixture.snapshotA)
        let displayUUID = try XCTUnwrap(fixture.snapshotA.displays[0].persistentID?.uuid)
        XCTAssertEqual(fixture.spaceProvider.snapshot(for: displayUUID).spaceID?.value,
                       "current-A")
        let maxConcurrency = await backend.maximumConcurrency
        XCTAssertEqual(maxConcurrency, 1)
        fixture.controller.dispose()
    }

    func testNonCooperativeReadTimesOutToDegradedAndExpiresPendingWithoutStartingIt() async throws {
        let callStarted = expectation(description: "held read starts")
        let backend = ControlledSpaceBackend(observer: BackendCallObserver(expectations: [1: callStarted]))
        let fixture = makeFixture(spaceBackend: backend, refreshDeadlineNanoseconds: 80_000_000)
        fixture.controller.start()
        await fulfillment(of: [callStarted], timeout: 2)

        fixture.sampled.snapshot = fixture.snapshotB
        fixture.workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await Task.yield()

        let opened = expectation(description: "deadline publishes degraded fallback while read remains held")
        fixture.effects.gateExpectations[false] = opened
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(fixture.spaceProvider.mode, .degradedScoped)
        XCTAssertTrue(fixture.validity.isAccepting)
        let callsWhileHeld = await backend.callCount
        XCTAssertEqual(callsWhileHeld, 1, "The pending request expires instead of starting beside the held call.")

        await backend.complete(call: 1, id: "too-late")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(fixture.spaceProvider.mode, .degradedScoped, "A late backend result cannot replace the timeout fallback.")
        let maxConcurrency = await backend.maximumConcurrency
        XCTAssertEqual(maxConcurrency, 1)
        fixture.controller.dispose()
    }

    func testLatestBackendFailurePublishesDegradedSnapshotAndReopensGate() async throws {
        let callStarted = expectation(description: "backend read starts")
        let backend = ControlledSpaceBackend(observer: BackendCallObserver(expectations: [1: callStarted]))
        let fixture = makeFixture(spaceBackend: backend)
        fixture.controller.start()
        await fulfillment(of: [callStarted], timeout: 2)

        let opened = expectation(description: "current read failure publishes degraded fallback")
        fixture.effects.gateExpectations[false] = opened
        await backend.fail(call: 1)
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(fixture.spaceProvider.mode, .degradedScoped)
        XCTAssertTrue(fixture.validity.isAccepting)
        fixture.controller.dispose()
    }

    func testReSampleMismatchRejectsCandidateAndPollStartsFreshRequest() async throws {
        let firstCallStarted = expectation(description: "initial read starts")
        let observer = BackendCallObserver(expectations: [1: firstCallStarted])
        let backend = ControlledSpaceBackend(observer: observer)
        let fixture = makeFixture(spaceBackend: backend)
        fixture.sampled.snapshot = fixture.snapshotA
        fixture.controller.start()
        await fulfillment(of: [firstCallStarted], timeout: 2)

        fixture.sampled.snapshot = fixture.snapshotB
        let delivered = expectation(description: "B request is accepted")
        fixture.effects.environmentChangeExpectations[2] = delivered
        fixture.workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await fulfillment(of: [delivered], timeout: 2)
        fixture.sampled.snapshot = fixture.snapshotA // Changes without a corresponding notification.

        let secondCallStarted = expectation(description: "B candidate call starts after initial slot returns")
        observer.expect(2, fulfills: secondCallStarted)
        await backend.fail(call: 1)
        await fulfillment(of: [secondCallStarted], timeout: 2)
        await backend.complete(call: 2, id: "mismatched-B")
        await Task.yield()
        XCTAssertFalse(fixture.validity.isAccepting, "A candidate for B cannot publish after resampling A.")
        XCTAssertEqual(fixture.spaceProvider.mode, .commonOnly)

        let retryStarted = expectation(description: "poll retries the current A request")
        observer.expect(3, fulfills: retryStarted)
        fixture.controller.pollForTesting()
        await fulfillment(of: [retryStarted], timeout: 2)
        let opened = expectation(description: "fresh A candidate opens gate")
        fixture.effects.gateExpectations[false] = opened
        await backend.complete(call: 3, id: "fresh-A")
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(fixture.spaceProvider.mode, .validatedScoped)
        fixture.controller.dispose()
    }

    func testSleepRejectsHeldCandidateUntilWakeStartsFreshRead() async throws {
        let firstCallStarted = expectation(description: "initial read starts")
        let secondCallStarted = expectation(description: "wake starts a fresh read")
        let observer = BackendCallObserver(expectations: [1: firstCallStarted, 2: secondCallStarted])
        let backend = ControlledSpaceBackend(observer: observer)
        let fixture = makeFixture(spaceBackend: backend)
        fixture.controller.start()
        await fulfillment(of: [firstCallStarted], timeout: 2)
        let sleepDelivered = expectation(description: "sleep invalidation reaches MainActor")
        fixture.controller.historyPermissionPollingSuspendedChanged = { sleeping in
            if sleeping { sleepDelivered.fulfill() }
        }
        fixture.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        await fulfillment(of: [sleepDelivered], timeout: 2)

        await backend.fail(call: 1)
        await Task.yield()
        XCTAssertEqual(fixture.spaceProvider.mode, .commonOnly, "The held pre-sleep failure cannot be adopted.")
        XCTAssertFalse(fixture.validity.isAccepting)

        let opened = expectation(description: "wake read is adopted")
        fixture.effects.gateExpectations[false] = opened
        fixture.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        await fulfillment(of: [secondCallStarted], timeout: 2)
        await backend.complete(call: 2, id: "after-wake")
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(fixture.spaceProvider.mode, .validatedScoped)
        fixture.controller.dispose()
    }

    func testShutdownThenCancelQuitRetainsRunningSlotUntilBackendReturns() async throws {
        let callStarted = expectation(description: "initial read starts")
        let secondCallStarted = expectation(description: "cancel quit read starts after old slot releases")
        let observer = BackendCallObserver(expectations: [1: callStarted, 2: secondCallStarted])
        let backend = ControlledSpaceBackend(observer: observer)
        let fixture = makeFixture(spaceBackend: backend, refreshDeadlineNanoseconds: 500_000_000)
        fixture.controller.start()
        await fulfillment(of: [callStarted], timeout: 2)
        fixture.controller.shutdown()

        let snapshotAfterShutdown = fixture.provider.snapshot
        fixture.controller.pollForTesting()
        await Task.yield()
        let callsAfterShutdownPoll = await backend.callCount
        XCTAssertEqual(callsAfterShutdownPoll, 1, "Polling cannot enqueue reads while the callback context is inactive.")
        XCTAssertFalse(fixture.validity.isAccepting)
        XCTAssertTrue(fixture.effects.gatePending)
        XCTAssertEqual(fixture.provider.snapshot, snapshotAfterShutdown, "Shutdown polling cannot publish cached configuration.")

        fixture.controller.cancelQuit()
        await Task.yield()
        let callsBeforeRelease = await backend.callCount
        XCTAssertEqual(callsBeforeRelease, 1, "Cancel Quit must wait behind the non-cooperative read.")

        await backend.complete(call: 1, id: "stale-after-shutdown")
        await fulfillment(of: [secondCallStarted], timeout: 2)
        let maxConcurrency = await backend.maximumConcurrency
        XCTAssertEqual(maxConcurrency, 1)
        let reopened = expectation(description: "cancel quit request is adopted")
        fixture.effects.gateExpectations[false] = reopened
        await backend.complete(call: 2, id: "after-cancel-quit")
        await fulfillment(of: [reopened], timeout: 2)
        let displayUUID = try XCTUnwrap(fixture.snapshotA.displays[0].persistentID?.uuid)
        XCTAssertEqual(fixture.spaceProvider.snapshot(for: displayUUID).spaceID?.value, "after-cancel-quit")
        fixture.controller.dispose()
    }

    private func makeFixture(registrationResult: CGError = .success, spaceBackend: ControlledSpaceBackend? = nil,
                             refreshDeadlineNanoseconds: UInt64 = 1_000_000_000) -> DisplayControllerFixture {
        let displayID = DisplaySelectionID.persistent(PersistentDisplayID(uuid: UUID()))
        let sessionID = UUID()
        let displayA = makeDisplay(id: displayID, sessionID: sessionID, originX: 0)
        let displayB = makeDisplay(id: displayID, sessionID: sessionID, originX: 40, runtimeID: 2)
        let snapshotA = DisplaySnapshot(displays: [displayA], primaryFrame: displayA.frame)
        let snapshotB = DisplaySnapshot(displays: [displayB], primaryFrame: displayB.frame)
        XCTAssertEqual(displayA.id, displayB.id, "Reconnect keeps the persistent display identity.")
        XCTAssertNotEqual(snapshotA.fingerprint, snapshotB.fingerprint, "A changed runtime ID must still advance configuration identity.")
        let provider = DisplayProvider(snapshot: snapshotA)
        let sampled = DisplaySnapshotBox(snapshotB)
        let validity = PlacementValidity()
        let appKit = NotificationCenter()
        let workspace = NotificationCenter()
        let spaceProvider: SpaceProvider
        if let spaceBackend {
            spaceProvider = .production(backend: spaceBackend, notificationCenter: workspace)
        } else {
            spaceProvider = SpaceProvider(notificationCenter: workspace)
        }
        let layout = LayoutController(displayProvider: provider, spaceProvider: spaceProvider, placementValidity: validity)
        let effects = DisplayEffectsRecorder()
        let registeredPointer = DisplayCallbackPointer()
        let controller = DisplayConfigurationController(
            layout: layout,
            effects: DisplayConfigurationController.Effects(
                cancelDrag: { _ in effects.dragCancellationCount += 1 },
                environmentChanged: { _ in effects.recordEnvironmentChange() },
                invalidateKeyboard: { effects.keyboardInvalidationCount += 1 },
                invalidateManualCapture: {},
                setConfigurationPending: { effects.setGate($0) }
            ),
            appKitNotificationCenter: appKit,
            workspaceNotificationCenter: workspace,
            registerCoreGraphics: { pointer in
                registeredPointer.pointer = pointer
                effects.coreGraphicsRegistrations += 1
                return registrationResult
            },
            removeCoreGraphics: { _ in effects.coreGraphicsRemovals += 1; return .success },
            sample: { sampled.snapshot }, refreshDeadlineNanoseconds: refreshDeadlineNanoseconds
        )
        return DisplayControllerFixture(controller: controller, layout: layout, provider: provider, snapshotA: snapshotA,
                                         snapshotB: snapshotB, sampled: sampled, validity: validity, spaceProvider: spaceProvider,
                                         effects: effects, appKit: appKit, workspace: workspace,
                                         registeredPointer: registeredPointer)
    }

    private func waitForInitialPublication(_ fixture: DisplayControllerFixture) async {
        let published = expectation(description: "initial asynchronous configuration publishes")
        fixture.effects.gateExpectations[false] = published
        await fulfillment(of: [published], timeout: 2)
    }

    private func completeConfigurationTransaction(_ fixture: DisplayControllerFixture,
                                                  oldTicket: PlacementCommitTicket) async throws {
        let pointer = try XCTUnwrap(fixture.registeredPointer.pointer)
        let began = expectation(description: "configuration begin is delivered")
        fixture.effects.gateExpectations[true] = began
        issue9DisplayReconfigured(0, .beginConfigurationFlag, pointer)
        XCTAssertFalse(fixture.validity.isAccepting, "The callback must close admission synchronously before MainActor delivery.")
        XCTAssertNil(fixture.validity.reserve(startDeadline: .max, totalDeadline: .max))
        await fulfillment(of: [began], timeout: 2)
        fixture.controller.pollForTesting()
        XCTAssertFalse(fixture.validity.isAccepting, "Polling during a CG transaction must not reopen admission.")

        let completion = expectation(description: "configuration completion is delivered")
        fixture.effects.gateExpectations[false] = completion
        issue9DisplayReconfigured(0, [], pointer)
        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(fixture.provider.snapshot, fixture.snapshotB)
        XCTAssertTrue(fixture.validity.isAccepting)
        XCTAssertEqual(oldTicket.state, .invalidated)
    }

    private func publishAAfterB(_ fixture: DisplayControllerFixture) async throws {
        fixture.sampled.snapshot = fixture.snapshotA
        let changed = expectation(description: "AppKit screen notification is delivered")
        let published = expectation(description: "final snapshot is published")
        fixture.effects.gateExpectations[true] = changed
        fixture.effects.gateExpectations[false] = published
        fixture.appKit.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await fulfillment(of: [changed, published], timeout: 2)
        XCTAssertEqual(fixture.provider.snapshot, fixture.snapshotA, "The observer must apply the final A snapshot after A-B-A.")
        XCTAssertTrue(fixture.validity.isAccepting)
    }

    private func verifySleepWake(_ fixture: DisplayControllerFixture) async throws {
        let sleeping = expectation(description: "sleep closes placement admission")
        fixture.effects.gateExpectations[true] = sleeping
        fixture.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        await fulfillment(of: [sleeping], timeout: 2)
        fixture.controller.pollForTesting()
        XCTAssertFalse(fixture.validity.isAccepting)
        XCTAssertNil(fixture.validity.reserve(startDeadline: .max, totalDeadline: .max))
        let awake = expectation(description: "wake republishes a fresh display snapshot")
        fixture.effects.gateExpectations[false] = awake
        fixture.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        await fulfillment(of: [awake], timeout: 2)
        XCTAssertTrue(fixture.validity.isAccepting)
    }

    private func verifyStaleObserverAndCancelQuit(_ fixture: DisplayControllerFixture, epoch: UInt64) {
        let staleRevision = fixture.validity.revision.configuration
        fixture.controller.shutdown()
        XCTAssertFalse(fixture.validity.isAccepting)
        XCTAssertFalse(fixture.controller.signalStaleObserverForTesting(expectedEpoch: epoch))
        fixture.controller.deliverStaleCallbackForTesting(revision: staleRevision, epoch: epoch)
        XCTAssertEqual(fixture.validity.revision.configuration, staleRevision + 1)
        let identity = fixture.controller.callbackContextIdentityForTesting
        fixture.controller.cancelQuit()
        XCTAssertEqual(fixture.controller.callbackContextIdentityForTesting, identity)
        XCTAssertEqual(fixture.effects.coreGraphicsRegistrations, 1, "Cancel Quit reuses the single registration context.")
        fixture.controller.dispose()
        XCTAssertEqual(fixture.effects.coreGraphicsRemovals, 1)
    }

    private func makeDisplay(id: DisplaySelectionID, sessionID: UUID, originX: CGFloat,
                             runtimeID: UInt32 = 1) -> Display {
        let persistentID: PersistentDisplayID?
        if case let .persistent(value) = id { persistentID = value } else { persistentID = nil }
        return Display(runtimeID: RuntimeDisplayID(rawValue: runtimeID), persistentID: persistentID,
                sessionID: sessionID, name: "test", frame: CGRect(x: originX, y: 0, width: 800, height: 600),
                workArea: CGRect(x: originX, y: 0, width: 800, height: 580), isPrimary: true, backingScaleFactor: 1)
    }
}

@MainActor
private struct DisplayControllerFixture {
    let controller: DisplayConfigurationController
    let layout: LayoutController
    let provider: DisplayProvider
    let snapshotA: DisplaySnapshot
    let snapshotB: DisplaySnapshot
    let sampled: DisplaySnapshotBox
    let validity: PlacementValidity
    let spaceProvider: SpaceProvider
    let effects: DisplayEffectsRecorder
    let appKit: NotificationCenter
    let workspace: NotificationCenter
    let registeredPointer: DisplayCallbackPointer
}

private actor ControlledSpaceBackend: ReadOnlySpaceBackend {
    nonisolated let identifier = "controlled-test"
    nonisolated let canAdoptStableIdentifiers = true
    private var calls = 0
    private var activeCalls = 0
    private var maximumActiveCalls = 0
    private var continuations: [Int: CheckedContinuation<ReadOnlySpaceValue?, Error>] = [:]
    private let observer: BackendCallObserver

    init(observer: BackendCallObserver) { self.observer = observer }

    var callCount: Int { calls }
    var maximumConcurrency: Int { maximumActiveCalls }

    func snapshot(for displayUUID: UUID) async throws -> ReadOnlySpaceValue? {
        calls += 1
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        let call = calls
        observer.signal(call)
        defer { activeCalls -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[call] = continuation
        }
    }

    func complete(call: Int, id: String) {
        continuations.removeValue(forKey: call)?.resume(returning: ReadOnlySpaceValue(id: id, kind: .regular))
    }

    func fail(call: Int) {
        continuations.removeValue(forKey: call)?.resume(throwing: ControlledSpaceReadError.failed)
    }
}

private enum ControlledSpaceReadError: Error { case failed }

private final class BackendCallObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var expectations: [Int: XCTestExpectation]

    init(expectations: [Int: XCTestExpectation]) { self.expectations = expectations }

    func expect(_ call: Int, fulfills expectation: XCTestExpectation) {
        lock.withLock { expectations[call] = expectation }
    }

    func signal(_ call: Int) {
        let expectation = lock.withLock { expectations.removeValue(forKey: call) }
        expectation?.fulfill()
    }
}

@MainActor
private final class DisplayEffectsRecorder {
    var dragCancellationCount = 0
    var environmentChangeCount = 0
    var keyboardInvalidationCount = 0
    var gatePending = false
    var gateExpectations: [Bool: XCTestExpectation] = [:]
    var environmentChangeExpectations: [Int: XCTestExpectation] = [:]
    var coreGraphicsRegistrations = 0
    var coreGraphicsRemovals = 0
    func setGate(_ pending: Bool) {
        gatePending = pending
        gateExpectations.removeValue(forKey: pending)?.fulfill()
    }
    func recordEnvironmentChange() {
        environmentChangeCount += 1
        environmentChangeExpectations.removeValue(forKey: environmentChangeCount)?.fulfill()
    }
}

private final class DisplaySnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DisplaySnapshot
    init(_ value: DisplaySnapshot) { self.value = value }
    var snapshot: DisplaySnapshot {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class DisplayCallbackPointer: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UnsafeMutableRawPointer?
    var pointer: UnsafeMutableRawPointer? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
