import XCTest

final class RuntimeWindowOwnershipTests: XCTestCase {
    func testRuntimeHistoryCapacityCountsUniqueTokensAndAllowsOneReplacementLease() async throws {
        let runtime = AccessibilityWindowRuntime(
            focusedWindowValidator: { _ in },
            accessibilityTrustedProvider: { true },
            historyObserverProvider: { _, _, _, _ in true }
        )
        var tokens: [RuntimeWindowToken] = []
        for index in 0 ..< 65 {
            let pid = pid_t(98_000 + index)
            let element = AXUIElementCreateApplication(pid)
            tokens.append(try await runtime.token(for: AXWindow(applicationElement: element, element: element, pid: pid)))
        }

        let firstLease = RuntimeHistoryLeaseID()
        let firstRetained = await runtime.retainHistoryLease(tokens[0], lease: firstLease)
        XCTAssertTrue(firstRetained)
        var leases = [firstLease]
        for index in 1 ..< 64 {
            let lease = RuntimeHistoryLeaseID()
            leases.append(lease)
            let retained = await runtime.retainHistoryLease(tokens[index], lease: lease)
            XCTAssertTrue(retained)
        }
        let replacement = RuntimeHistoryLeaseID()
        let replacementRetained = await runtime.retainHistoryLease(tokens[0], lease: replacement)
        XCTAssertTrue(replacementRetained)
        let replacementCount = await runtime.historyLeaseCount(for: tokens[0])
        XCTAssertEqual(replacementCount, 2)
        let thirdRetained = await runtime.retainHistoryLease(tokens[0], lease: RuntimeHistoryLeaseID())
        XCTAssertFalse(thirdRetained)
        let sixtyFifthRetained = await runtime.retainHistoryLease(tokens[64], lease: RuntimeHistoryLeaseID())
        XCTAssertFalse(sixtyFifthRetained)

        await runtime.releaseHistoryLease(tokens[0], lease: replacement)
        let remainingCount = await runtime.historyLeaseCount(for: tokens[0])
        XCTAssertEqual(remainingCount, 1)
        await runtime.releaseHistoryLease(tokens[63], lease: leases[63])
    }

    func testRuntimeMonitorSeenLeasesRetainRecordsAndReleaseOnlyTheirOwnSlot() async throws {
        let runtime = AccessibilityWindowRuntime(focusedWindowValidator: { _ in }, accessibilityTrustedProvider: { true })
        var tokens: [RuntimeWindowToken] = []
        for index in 0 ..< 65 {
            let pid = pid_t(97_000 + index)
            let element = AXUIElementCreateApplication(pid)
            tokens.append(try await runtime.token(for: AXWindow(applicationElement: element, element: element, pid: pid)))
        }
        var leases: [RuntimeMonitorSeenLeaseID] = []
        for token in tokens.prefix(64) {
            let lease = RuntimeMonitorSeenLeaseID()
            leases.append(lease)
            let retained = await runtime.retainMonitorSeenLease(token, lease: lease)
            XCTAssertTrue(retained)
        }
        let sixtyFifthRetained = await runtime.retainMonitorSeenLease(tokens[64], lease: RuntimeMonitorSeenLeaseID())
        XCTAssertFalse(sixtyFifthRetained)
        let trackedCount = await runtime.retainedMonitorSeenTokenCount
        XCTAssertEqual(trackedCount, 64)
        let replacementLease = RuntimeMonitorSeenLeaseID()
        let replacementRetained = await runtime.retainMonitorSeenLease(tokens[1], lease: replacementLease)
        XCTAssertTrue(replacementRetained, "An already-seen token may temporarily retain its replacement lease at capacity.")
        let extraLeaseRetained = await runtime.retainMonitorSeenLease(tokens[1], lease: RuntimeMonitorSeenLeaseID())
        XCTAssertFalse(extraLeaseRetained, "A token may hold at most two monitor leases.")
        await runtime.releaseMonitorSeenLease(tokens[0], lease: leases[0])
        let firstCount = await runtime.monitorSeenLeaseCount(for: tokens[0])
        XCTAssertEqual(firstCount, 0)
        let reusedSlot = await runtime.retainMonitorSeenLease(tokens[64], lease: RuntimeMonitorSeenLeaseID())
        XCTAssertTrue(reusedSlot)
        let unrelatedCount = await runtime.monitorSeenLeaseCount(for: tokens[1])
        XCTAssertEqual(unrelatedCount, 2)
    }

    func testManualLeaseProtectsWindowAndReleasesIndependentlyFromKeyboardAndDragOwners() {
        let manual = ManualWindowLeaseID()
        let drag = DragLeaseID(rawValue: UUID())
        var ownership = RuntimeWindowOwnership()
        ownership.retainKeyboard()
        ownership.retainManual(manual)
        ownership.retainDrag(drag)
        ownership.releaseManual(manual)
        XCTAssertTrue(ownership.isOwned)
        XCTAssertTrue(ownership.manualLeases.isEmpty)
        XCTAssertTrue(ownership.dragLeases.contains(drag))
        XCTAssertTrue(ownership.keyboardRetained)
        ownership.releaseDrag(drag)
        XCTAssertTrue(ownership.isOwned)
        ownership.discardKeyboard()
        XCTAssertFalse(ownership.isOwned)
    }

    func testActualFocusedWindowPathRechecksOwnershipAfterPreflightAwait() async throws {
        for teardown in [RuntimeTeardown.discard, .shutdown] {
            let pid: pid_t = 99001
            let application = AXUIElementCreateApplication(pid)
            let window = AXWindow(applicationElement: application, element: application, pid: pid)
            let runtime = AccessibilityWindowRuntime(
                focusedWindowProvider: { _ in window },
                focusedWindowValidator: { _ in },
                frontmostPIDProvider: { pid },
                accessibilityTrustedProvider: { true }
            )
            let token = try await runtime.token(for: window)
            await runtime.retain(token)
            let validity = PlacementValidity()
            let ticket = try XCTUnwrap(validity.reserve(startDeadline: .max, totalDeadline: .max))
            let barrier = RuntimePreflightBarrier()
            let writes = RuntimeWriteCounter()
            let operation = Task {
                try await runtime.withCurrentFocusedWindow(token, ticket: ticket, preflight: {
                    barrier.pause()
                }, operation: { _ in
                    writes.increment()
                    return CGRect(x: 20, y: 30, width: 400, height: 300)
                })
            }
            XCTAssertEqual(barrier.entered.wait(timeout: .now() + 2), .success)
            switch teardown {
            case .discard: await runtime.discard(token)
            case .shutdown: await runtime.shutdown()
            }
            barrier.resume.signal()
            do {
                _ = try await operation.value
                XCTFail("Teardown during preflight must reject the write.")
            } catch {
                XCTAssertEqual(writes.value, 0)
            }
        }
    }

    func testActualFocusedWindowPathRejectsTargetSwitchAfterPreflightAwait() async throws {
        let pid: pid_t = 99002
        let first = AXUIElementCreateApplication(pid)
        let second = AXUIElementCreateSystemWide()
        let windows = RuntimeFocusedWindowBox(AXWindow(applicationElement: first, element: first, pid: pid))
        let runtime = AccessibilityWindowRuntime(
            focusedWindowProvider: { _ in windows.read() },
            focusedWindowValidator: { _ in },
            frontmostPIDProvider: { pid },
            accessibilityTrustedProvider: { true }
        )
        let original = windows.read()
        let token = try await runtime.token(for: original)
        await runtime.retain(token)
        let validity = PlacementValidity()
        let ticket = try XCTUnwrap(validity.reserve(startDeadline: .max, totalDeadline: .max))
        let barrier = RuntimePreflightBarrier()
        let writes = RuntimeWriteCounter()
        let operation = Task {
            try await runtime.withCurrentFocusedWindow(token, ticket: ticket, preflight: {
                barrier.pause()
            }, operation: { _ in
                writes.increment()
                return CGRect.zero
            })
        }
        XCTAssertEqual(barrier.entered.wait(timeout: .now() + 2), .success)
        windows.replace(AXWindow(applicationElement: second, element: second, pid: pid))
        barrier.resume.signal()
        do {
            _ = try await operation.value
            XCTFail("A changed focused AX target must reject the write.")
        } catch {
            XCTAssertEqual(writes.value, 0)
        }
    }

    func testNavigationResetInvalidatesExtensionTicketAtRuntimeBeginWriteBoundary() async throws {
        let pid: pid_t = 99003
        let application = AXUIElementCreateApplication(pid)
        let window = AXWindow(applicationElement: application, element: application, pid: pid)
        let providerBarrier = RuntimeFocusedWindowProviderBarrier(window: window)
        let runtime = AccessibilityWindowRuntime(
            focusedWindowProvider: { _ in providerBarrier.provideWindow() },
            focusedWindowValidator: { _ in },
            frontmostPIDProvider: { pid },
            accessibilityTrustedProvider: { true }
        )
        let token = try await runtime.token(for: window)
        await runtime.retain(token)

        let workArea = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: PersistentDisplayID(uuid: UUID()),
                              sessionID: UUID(), name: "Test", frame: workArea, workArea: workArea,
                              isPrimary: true, backingScaleFactor: 1)
        let (controller, ticket) = await MainActor.run { () -> (KeyboardSnapController, PlacementCommitTicket) in
            let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: workArea)))
            var settings = layout.keyboardSettings
            settings.isEnabled = true
            layout.updateKeyboardSettings(settings)
            let controller = KeyboardSnapController(
                layoutController: layout,
                backend: runtime,
                environment: KeyboardEnvironment(frontmostPID: { pid }, isAccessibilityTrusted: { true }, ownPID: 100)
            )
            controller.flagsMonitorStatus(.ready)
            let now = DispatchTime.now().uptimeNanoseconds
            let ticket = layout.placementValidity.reserve(startDeadline: now + 2_000_000_000,
                                                           totalDeadline: now + 5_000_000_000)!
            controller.installActiveExtensionTicket(ticket, token: token)
            return (controller, ticket)
        }
        let capturedGeneration = await MainActor.run { controller.extensionHistoryGeneration }
        let setterStarts = RuntimeWriteCounter()
        let operation = Task {
            try await runtime.withCurrentFocusedWindow(token, ticket: ticket, preflight: {
                controller.extensionHistoryGeneration == capturedGeneration
            }, operation: { _ in
                setterStarts.increment()
                return CGRect(x: 10, y: 20, width: 300, height: 200)
            })
        }

        XCTAssertEqual(providerBarrier.entered.wait(timeout: .now() + 2), .success,
                       "The provider barrier runs after preflight returned true and before beginWrite.")
        await MainActor.run { controller.resetNavigationHistory(for: WorkAreaKey(display: display.id, spaceScope: nil)) }
        providerBarrier.resume.signal()
        do {
            _ = try await operation.value
            XCTFail("Reset must invalidate the extension-owned ticket before the runtime setter begins.")
        } catch {
            XCTAssertEqual(setterStarts.value, 0)
        }
        XCTAssertEqual(ticket.state, .invalidated)
        XCTAssertFalse(ticket.beginWrite(now: DispatchTime.now().uptimeNanoseconds))
        XCTAssertFalse(ticket.mayContinueWrite(now: DispatchTime.now().uptimeNanoseconds))
        XCTAssertFalse(ticket.completeIfCurrent(now: DispatchTime.now().uptimeNanoseconds))
        await MainActor.run { controller.finishActiveTicket(ticket) }
        await runtime.shutdown()
    }

}

extension RuntimeWindowOwnershipTests {
    func testKeyboardDiscardKeepsRecordWhileDragLeaseIsActive() {
        var ownership = RuntimeWindowOwnership()
        let lease = DragLeaseID(rawValue: UUID())
        ownership.retainKeyboard()
        ownership.retainDrag(lease)
        ownership.discardKeyboard()
        XCTAssertTrue(ownership.isOwned)
        XCTAssertTrue(ownership.dragLeases.contains(lease))
    }

    func testDragReleaseKeepsKeyboardOriginalFrameRecordAndIsIdempotent() {
        var ownership = RuntimeWindowOwnership()
        let lease = DragLeaseID(rawValue: UUID())
        ownership.retainKeyboard()
        ownership.retainDrag(lease)
        ownership.releaseDrag(lease)
        ownership.releaseDrag(lease)
        XCTAssertTrue(ownership.isOwned)
        XCTAssertTrue(ownership.keyboardRetained)
        XCTAssertTrue(ownership.dragLeases.isEmpty)
    }

    func testUnownedRecordCanBeEvictedOnlyAfterBothOwnersRelease() {
        var ownership = RuntimeWindowOwnership()
        let lease = DragLeaseID(rawValue: UUID())
        ownership.retainKeyboard()
        ownership.retainDrag(lease)
        XCTAssertTrue(ownership.isOwned)
        ownership.discardKeyboard()
        XCTAssertTrue(ownership.isOwned)
        ownership.releaseDrag(lease)
        XCTAssertFalse(ownership.isOwned)
    }

    func testReleasingUnknownLeaseDoesNotAffectAnotherGesture() {
        var ownership = RuntimeWindowOwnership()
        let liveLease = DragLeaseID(rawValue: UUID())
        ownership.retainDrag(liveLease)
        ownership.releaseDrag(DragLeaseID(rawValue: UUID()))
        XCTAssertTrue(ownership.dragLeases.contains(liveLease))
        XCTAssertTrue(ownership.isOwned)
    }

    func testCommitHandoffKeepsOwnershipContinuousAndReleasesAreIdempotent() {
        var ownership = RuntimeWindowOwnership()
        let drag = DragLeaseID(rawValue: UUID())
        let commit = DragCommitID()
        ownership.retainKeyboard()
        ownership.retainDrag(drag)
        XCTAssertTrue(ownership.handoffDrag(drag, to: commit))
        XCTAssertTrue(ownership.isOwned)
        XCTAssertTrue(ownership.keyboardRetained)
        XCTAssertFalse(ownership.dragLeases.contains(drag))
        XCTAssertTrue(ownership.dragCommits.contains(commit))
        ownership.releaseDrag(drag)
        ownership.releaseDragCommit(commit)
        ownership.releaseDragCommit(commit)
        XCTAssertTrue(ownership.isOwned, "Keyboard Restore ownership must outlive drag cleanup.")
        XCTAssertTrue(ownership.keyboardRetained)
        ownership.discardKeyboard()
        XCTAssertFalse(ownership.isOwned)
    }

    func testAXRevisionRemembersResizeAfterLaterMoveAndDestroyedIsSticky() {
        let tracker = AXRevisionTracker()
        tracker.record(kAXResizedNotification as String)
        let revisionAfterResize = tracker.snapshot(since: 0)
        XCTAssertEqual(revisionAfterResize.revision, 1)
        XCTAssertTrue(revisionAfterResize.changeWasResize)
        XCTAssertEqual(revisionAfterResize.changes.map(\.kind), [.resized])

        tracker.record(kAXMovedNotification as String)
        let revisionAfterMove = tracker.snapshot(since: 0)
        XCTAssertEqual(revisionAfterMove.revision, 2)
        XCTAssertTrue(revisionAfterMove.changeWasResize)
        XCTAssertEqual(revisionAfterMove.changes.map(\.kind), [.resized, .moved])
        XCTAssertFalse(tracker.snapshot(since: UInt64.max).changeWasResize)

        tracker.record(kAXUIElementDestroyedNotification as String)
        tracker.record(kAXMovedNotification as String)
        XCTAssertTrue(tracker.snapshot(since: 0).destroyed)
    }

    func testMonitorGenerationRejectsLateTapAndOldDrainAfterStopAndRetry() {
        var generation = InputMonitorGeneration()
        let first = generation.start()
        XCTAssertTrue(generation.accepts(first))
        generation.stop()
        XCTAssertFalse(generation.accepts(first))
        let second = generation.start()
        XCTAssertGreaterThan(second, first)
        XCTAssertFalse(generation.accepts(first))
        XCTAssertTrue(generation.accepts(second))
        generation.stop()
        XCTAssertFalse(generation.accepts(second))
    }
}

private enum RuntimeTeardown { case discard, shutdown }

private final class RuntimePreflightBarrier: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    @MainActor func pause() -> Bool {
        entered.signal()
        _ = resume.wait(timeout: .now() + 3)
        return true
    }
}

private final class RuntimeWriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class RuntimeFocusedWindowBox: @unchecked Sendable {
    private let lock = NSLock()
    private var window: AXWindow
    init(_ window: AXWindow) { self.window = window }
    func read() -> AXWindow { lock.withLock { window } }
    func replace(_ window: AXWindow) { lock.withLock { self.window = window } }
}

private final class RuntimeFocusedWindowProviderBarrier: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var callCount = 0
    private let window: AXWindow

    init(window: AXWindow) { self.window = window }

    func provideWindow() -> AXWindow {
        let shouldPause = lock.withLock { () -> Bool in
            callCount += 1
            return callCount == 2
        }
        if shouldPause {
            entered.signal()
            _ = resume.wait(timeout: .now() + 3)
        }
        return window
    }
}
