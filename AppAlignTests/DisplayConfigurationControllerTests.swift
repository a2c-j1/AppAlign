import AppKit
import CoreGraphics
import XCTest

@MainActor
final class DisplayConfigurationControllerTests: XCTestCase {
    func testRegistrationFailureRemainsVisibleAndNotificationFallbackWorks() async throws {
        let fixture = makeFixture(registrationResult: .failure)
        fixture.controller.start()
        XCTAssertTrue(fixture.controller.monitoringDiagnostics.contains {
            $0.contains("callback registration failed")
        })
        let changed = expectation(description: "AppKit observer remains active after CG registration failure")
        fixture.effects.gateExpectations[true] = changed
        fixture.appKit.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertTrue(fixture.validity.isAccepting)
        fixture.controller.dispose()
    }

    func testCGBeginAndNotificationDeliveryKeepGateClosedUntilCompletionAndRestoreABA() async throws {
        let fixture = makeFixture()
        fixture.controller.start()
        let oldTicket = try XCTUnwrap(fixture.validity.reserve(startDeadline: .max, totalDeadline: .max))
        let oldEpoch = fixture.controller.callbackEpochForTesting
        try await completeConfigurationTransaction(fixture, oldTicket: oldTicket)
        try await publishAAfterB(fixture)
        try await verifySleepWake(fixture)
        verifyStaleObserverAndCancelQuit(fixture, epoch: oldEpoch)
    }

    func testSleepThenDisplayAndCGCompletionBeforeDeliveryStaysClosedUntilWake() async throws {
        let fixture = makeFixture()
        fixture.controller.start()
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
        XCTAssertFalse(fixture.validity.isAccepting)
        XCTAssertEqual(fixture.provider.snapshot, fixture.snapshotA)
        XCTAssertNil(fixture.layout.appliedLayoutSnapshot(for: fixture.snapshotA.displays[0].frame))
        XCTAssertNil(fixture.layout.appliedDragLayoutSnapshot(at: CGPoint(x: 10, y: 10)))

        fixture.sampled.snapshot = fixture.snapshotB
        let awake = expectation(description: "wake publishes the latest sampled display")
        fixture.effects.gateExpectations[false] = awake
        fixture.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        await fulfillment(of: [awake], timeout: 2)
        XCTAssertEqual(fixture.provider.snapshot, fixture.snapshotB)
        XCTAssertTrue(fixture.validity.isAccepting)
        fixture.controller.dispose()
    }

    func testWakeThenDisplayAndCGCompletionBeforeDeliveryPublishesOnlyLatestSnapshot() async throws {
        let fixture = makeFixture()
        fixture.controller.start()
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

    private func makeFixture(registrationResult: CGError = .success) -> DisplayControllerFixture {
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
        let layout = LayoutController(displayProvider: provider, placementValidity: validity)
        let effects = DisplayEffectsRecorder()
        let appKit = NotificationCenter()
        let workspace = NotificationCenter()
        let registeredPointer = DisplayCallbackPointer()
        let controller = DisplayConfigurationController(
            layout: layout,
            effects: DisplayConfigurationController.Effects(
                cancelDrag: { _ in effects.dragCancellationCount += 1 },
                environmentChanged: { _ in effects.environmentChangeCount += 1 },
                invalidateKeyboard: { effects.keyboardInvalidationCount += 1 },
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
            sample: { sampled.snapshot }
        )
        return DisplayControllerFixture(controller: controller, layout: layout, provider: provider, snapshotA: snapshotA,
                                         snapshotB: snapshotB, sampled: sampled, validity: validity,
                                         effects: effects, appKit: appKit, workspace: workspace,
                                         registeredPointer: registeredPointer)
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
    let effects: DisplayEffectsRecorder
    let appKit: NotificationCenter
    let workspace: NotificationCenter
    let registeredPointer: DisplayCallbackPointer
}

@MainActor
private final class DisplayEffectsRecorder {
    var dragCancellationCount = 0
    var environmentChangeCount = 0
    var keyboardInvalidationCount = 0
    var gatePending = false
    var gateExpectations: [Bool: XCTestExpectation] = [:]
    var coreGraphicsRegistrations = 0
    var coreGraphicsRemovals = 0
    func setGate(_ pending: Bool) {
        gatePending = pending
        gateExpectations.removeValue(forKey: pending)?.fulfill()
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
