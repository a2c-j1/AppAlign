import AppKit
import CoreGraphics
import XCTest

final class DragSnapTests: XCTestCase {
    @MainActor
    func testStaticShiftDownAtStationaryPointerCommitsExactlyOnceAndHidesOverlay() async throws {
        let fixture = DragFixture()
        let display = makeDisplay()
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)))
        let overlay = FakeZoneOverlay()
        let snap = DragSnapController(layoutController: layout, runtime: fixture.reader, overlay: overlay)
        let snapGate = TestDragGate()
        fixture.controller.onWillEnd = { snap.prepareCommit($0) }
        fixture.controller.onAcceptedInput = { snap.acceptedInput($0) }
        fixture.controller.onCommitCancelled = { snap.cancel(reason: $0) }
        fixture.controller.onLifecycle = { snap.lifecycle($0) }
        fixture.controller.dragGateChanged = { snapGate.setDrag($0) }
        snap.gateChanged = { snapGate.recordCommit($0) }

        fixture.start()
        await fixture.reader.focusDifferentWindow()
        fixture.send(.leftDown, gesture: 1, point: CGPoint(x: 20, y: 20))
        try await spin { fixture.controller.captureRequestCount == 0 }
        await fixture.reader.setFrame(CGRect(x: 80, y: 0, width: 400, height: 300))
        fixture.send(.leftDragged, gesture: 1, point: CGPoint(x: 100, y: 20))
        try await spin { fixture.controller.frameRequestCount == 0 }
        fixture.send(.leftDragged, gesture: 1, point: CGPoint(x: 100, y: 20))
        try await spin { fixture.controller.frameRequestCount == 0 }

        let shift = CGEventFlags.maskShift.rawValue
        fixture.send(.flagsChanged, gesture: 1, point: CGPoint(x: 100, y: 20), flags: shift)
        XCTAssertTrue(overlay.isVisible, "Shift down should update selection without another pointer sample.")
        let shownCount = overlay.showCount
        fixture.send(.leftUp, gesture: 1, point: CGPoint(x: 100, y: 20), flags: shift)
        try await spin { await fixture.reader.commitCount == 1 }
        try await spin { !snap.isCommitting }

        let expected = try XCTUnwrap(layout.appliedDragLayoutSnapshot(at: CGPoint(x: 100, y: 20))?.zones.first?.frame)
        let actual = await fixture.reader.currentFrameValue()
        let focused = await fixture.reader.focusedWindow(applicationPID: 3, ownPID: 1)
        let dragToken = await fixture.reader.tokenValue()
        XCTAssertEqual(actual, expected)
        XCTAssertNotEqual(focused.token, dragToken)
        let commitCount = await fixture.reader.commitCount
        XCTAssertEqual(commitCount, 1)
        XCTAssertFalse(overlay.isVisible)
        XCTAssertGreaterThanOrEqual(overlay.showCount, shownCount)
        let owners = await fixture.reader.ownerSnapshot
        XCTAssertTrue(owners.dragCommits.isEmpty)
        XCTAssertTrue(owners.dragLeases.isEmpty)
        fixture.stop()
    }

    @MainActor
    func testCancellationWhileCommitPreflightIsDelayedPreventsWrite() async throws {
        let display = makeDisplay()
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)))
        let runtime = FakeDragReader()
        let snap = DragSnapController(layoutController: layout, runtime: runtime, overlay: FakeZoneOverlay())
        let snapshot = try XCTUnwrap(layout.appliedDragLayoutSnapshot(at: CGPoint(x: 20, y: 20)))
        let lease = DragLeaseID(rawValue: UUID())
        await runtime.retainFakeLease(lease)
        let now = DispatchTime.now().uptimeNanoseconds
        let ticket = DragCommitTicket(startDeadline: now + 2_000_000_000, totalDeadline: now + 5_000_000_000)
        let zone = try XCTUnwrap(ZoneSelectionEngine.select(point: CGPoint(x: 20, y: 20), zones: snapshot.zones,
                                                             workArea: display.workArea, radius: 20))
        let offer = DragCommitOffer(id: DragCommitID(), run: 1, session: 1, inputEpoch: 1, gesture: 1,
                                    token: await runtime.tokenValue(), sourceLease: lease,
                                    originalFrame: CGRect(x: 0, y: 0, width: 400, height: 300), targetFrame: zone.frame,
                                    point: CGPoint(x: 20, y: 20), flags: CGEventFlags.maskShift.rawValue,
                                    timestamp: 1, sequence: 1, displayFingerprint: snapshot.fingerprint,
                                    layoutRevision: snapshot.revision, workAreaKey: snapshot.workAreaKey,
                                    zoneID: zone.id, layoutSnapshot: snapshot, ticket: ticket)
        await runtime.blockCommit()
        XCTAssertTrue(snap.accept(offer))
        try await spin { await runtime.commitBlocked }
        snap.cancel(reason: "Escape")
        await runtime.resumeCommit()
        try await spin { !snap.isCommitting }
        let count = await runtime.commitCount
        let owners = await runtime.ownerSnapshot
        XCTAssertEqual(count, 0)
        XCTAssertTrue(owners.dragCommits.isEmpty)
    }

    @MainActor
    func testExpiredBeforeHandoffReleasesClaimedSourceAndNeverWrites() async throws {
        let display = makeDisplay()
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)))
        let runtime = FakeDragReader()
        let overlay = FakeZoneOverlay()
        let snap = DragSnapController(layoutController: layout, runtime: runtime, overlay: overlay)
        let snapshot = try XCTUnwrap(layout.appliedDragLayoutSnapshot(at: CGPoint(x: 20, y: 20)))
        let lease = DragLeaseID(rawValue: UUID())
        await runtime.retainFakeLease(lease)
        let now = DispatchTime.now().uptimeNanoseconds
        let zone = try XCTUnwrap(snapshot.zones.first)
        let offer = DragCommitOffer(id: DragCommitID(), run: 1, session: 1, inputEpoch: 1, gesture: 1,
                                    token: await runtime.tokenValue(), sourceLease: lease,
                                    originalFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
                                    targetFrame: zone.frame, point: CGPoint(x: 20, y: 20), flags: 0,
                                    timestamp: 1, sequence: 1, displayFingerprint: snapshot.fingerprint,
                                    layoutRevision: snapshot.revision, workAreaKey: snapshot.workAreaKey,
                                    zoneID: zone.id, layoutSnapshot: snapshot,
                                    ticket: DragCommitTicket(startDeadline: now - 1, totalDeadline: now - 1))
        XCTAssertTrue(snap.accept(offer))
        try await spin { !snap.isCommitting }
        let writes = await runtime.commitCount
        let owners = await runtime.ownerSnapshot
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(owners.dragLeases.isEmpty)
        XCTAssertTrue(owners.dragCommits.isEmpty)
        XCTAssertFalse(overlay.isVisible)
    }

    @MainActor
    func testOldCommitCleanupCannotReleaseNextGestureLeaseOrHideItsOverlay() async throws {
        let display = makeDisplay()
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)))
        let runtime = FakeDragReader()
        let overlay = FakeZoneOverlay()
        let snap = DragSnapController(layoutController: layout, runtime: runtime, overlay: overlay)
        let point = CGPoint(x: 20, y: 20)
        let snapshot = try XCTUnwrap(layout.appliedDragLayoutSnapshot(at: point))
        let zone = try XCTUnwrap(snapshot.zones.first)
        let token = await runtime.tokenValue()
        func offer(lease: DragLeaseID, session: UInt64) -> DragCommitOffer {
            let now = DispatchTime.now().uptimeNanoseconds
            return DragCommitOffer(id: DragCommitID(), run: 1, session: session, inputEpoch: 1, gesture: session,
                                   token: token, sourceLease: lease,
                                   originalFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
                                   targetFrame: zone.frame, point: point, flags: CGEventFlags.maskShift.rawValue,
                                   timestamp: session, sequence: session, displayFingerprint: snapshot.fingerprint,
                                   layoutRevision: snapshot.revision, workAreaKey: snapshot.workAreaKey,
                                   zoneID: zone.id, layoutSnapshot: snapshot,
                                   ticket: DragCommitTicket(startDeadline: now + 2_000_000_000,
                                                            totalDeadline: now + 5_000_000_000))
        }

        let oldLease = DragLeaseID(rawValue: UUID())
        await runtime.retainFakeLease(oldLease)
        await runtime.blockCommit()
        XCTAssertTrue(snap.accept(offer(lease: oldLease, session: 1)))
        try await spin { await runtime.commitBlocked }
        await runtime.releaseDragLease(oldLease)
        var owners = await runtime.ownerSnapshot
        XCTAssertEqual(owners.dragCommits.count, 1, "Releasing the source after handoff must retain the commit owner.")
        snap.cancel(reason: "Superseded")

        let nextLease = DragLeaseID(rawValue: UUID())
        await runtime.retainFakeLease(nextLease)
        let nextOffer = offer(lease: nextLease, session: 2)
        XCTAssertFalse(snap.accept(nextOffer), "The in-flight slot stays occupied until the old backend call drains.")
        var nextLifecycle = DragLifecycleEvent(kind: .began, session: 2, frame: nil, reason: nil)
        nextLifecycle.point = point
        nextLifecycle.flags = CGEventFlags.maskShift.rawValue
        snap.lifecycle(nextLifecycle)
        XCTAssertTrue(overlay.isVisible)

        await runtime.resumeCommit()
        try await spin { !snap.isCommitting }
        let staleWrites = await runtime.commitCount
        owners = await runtime.ownerSnapshot
        XCTAssertEqual(staleWrites, 0)
        XCTAssertTrue(owners.dragLeases.contains(nextLease))
        XCTAssertTrue(overlay.isVisible, "Old commit completion must not hide the next gesture's overlay.")

        XCTAssertTrue(snap.accept(nextOffer))
        try await spin { !snap.isCommitting }
        let totalWrites = await runtime.commitCount
        XCTAssertEqual(totalWrites, 1)
        owners = await runtime.ownerSnapshot
        XCTAssertTrue(owners.dragLeases.isEmpty)
        XCTAssertTrue(owners.dragCommits.isEmpty)
    }

    @MainActor
    func testEnvironmentChangeCancelsGestureAndLateInputCannotReshowOverlayOrCommit() async throws {
        let fixture = DragFixture()
        let display = makeDisplay()
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)))
        let overlay = FakeZoneOverlay()
        let snap = DragSnapController(layoutController: layout, runtime: fixture.reader, overlay: overlay)
        fixture.controller.onWillEnd = { snap.prepareCommit($0) }
        fixture.controller.onAcceptedInput = { snap.acceptedInput($0) }
        fixture.controller.onCommitCancelled = { snap.cancel(reason: $0) }
        fixture.controller.onLifecycle = { snap.lifecycle($0) }
        layout.invalidateDragCommit = {
            snap.cancel(reason: "Applied layout changed.")
            fixture.controller.environmentChanged(reason: "Applied layout changed.")
        }
        fixture.start()
        try await fixture.becomeMoving()
        fixture.send(.flagsChanged, gesture: 1, point: CGPoint(x: 100, y: 20), flags: CGEventFlags.maskShift.rawValue)
        XCTAssertTrue(overlay.isVisible)

        layout.template = .columns
        layout.recalculate()
        XCTAssertFalse(overlay.isVisible)
        fixture.send(.flagsChanged, gesture: 1, point: CGPoint(x: 100, y: 20), flags: CGEventFlags.maskShift.rawValue)
        fixture.send(.leftDragged, gesture: 1, point: CGPoint(x: 100, y: 20), flags: CGEventFlags.maskShift.rawValue)
        fixture.send(.leftUp, gesture: 1, point: CGPoint(x: 100, y: 20), flags: CGEventFlags.maskShift.rawValue)
        await Task.yield()
        let writes = await fixture.reader.commitCount
        XCTAssertFalse(overlay.isVisible)
        XCTAssertEqual(writes, 0)
        fixture.stop()
    }

    private func makeDisplay() -> Display {
        Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: PersistentDisplayID(uuid: UUID()),
                sessionID: UUID(), name: "Test", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800), isPrimary: true, backingScaleFactor: 1)
    }
}

final class DragKeyboardRestoreTests: XCTestCase {
    @MainActor
    func testKeyboardOriginalFrameSurvivesDragCommitAndRealRestoreAction() async throws {
        let display = makeDisplay()
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)))
        var keyboardSettings = layout.keyboardSettings
        keyboardSettings.isEnabled = true
        layout.keyboardSettings = keyboardSettings
        let runtime = FakeDragReader()
        let original = await runtime.currentFrameValue()
        let keyboard = KeyboardSnapController(
            layoutController: layout,
            backend: runtime,
            environment: KeyboardEnvironment(frontmostPID: { 2 }, isAccessibilityTrusted: { true }, ownPID: 1)
        )
        keyboard.handle(.zone(ZoneID(rawValue: 1)))
        try await spin { keyboard.hasRestoreTarget && !keyboard.isBusy }
        XCTAssertTrue(keyboard.hasRestoreTarget)

        let lease = DragLeaseID(rawValue: UUID())
        await runtime.retainFakeLease(lease)
        let snapshot = try XCTUnwrap(layout.appliedDragLayoutSnapshot(at: CGPoint(x: 700, y: 100)))
        let zone = try XCTUnwrap(snapshot.zones.first)
        let now = DispatchTime.now().uptimeNanoseconds
        let offer = DragCommitOffer(id: DragCommitID(), run: 1, session: 2, inputEpoch: 1, gesture: 2,
                                    token: await runtime.tokenValue(), sourceLease: lease,
                                    originalFrame: original, targetFrame: zone.frame,
                                    point: CGPoint(x: 700, y: 100), flags: CGEventFlags.maskShift.rawValue,
                                    timestamp: 2, sequence: 2, displayFingerprint: snapshot.fingerprint,
                                    layoutRevision: snapshot.revision, workAreaKey: snapshot.workAreaKey,
                                    zoneID: zone.id, layoutSnapshot: snapshot,
                                    ticket: DragCommitTicket(startDeadline: now + 2_000_000_000,
                                                             totalDeadline: now + 5_000_000_000))
        let snap = DragSnapController(layoutController: layout, runtime: runtime, overlay: FakeZoneOverlay())
        XCTAssertTrue(snap.accept(offer))
        try await spin { !snap.isCommitting }
        let ownershipAfterDrag = await runtime.ownerSnapshot
        XCTAssertTrue(ownershipAfterDrag.keyboardRetained)
        XCTAssertTrue(keyboard.hasRestoreTarget)

        keyboard.handle(.restore)
        try await spin { !keyboard.isBusy }
        let restored = await runtime.currentFrameValue()
        let ownershipAfterRestore = await runtime.ownerSnapshot
        XCTAssertEqual(restored, original)
        XCTAssertFalse(keyboard.hasRestoreTarget)
        XCTAssertFalse(ownershipAfterRestore.keyboardRetained)
    }

    private func makeDisplay() -> Display {
        Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: PersistentDisplayID(uuid: UUID()),
                sessionID: UUID(), name: "Test", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800), isPrimary: true, backingScaleFactor: 1)
    }
}

final class DragZoneSelectionTests: XCTestCase {
    func testSelectionUsesStrictHalfOpenBoundsAndStableLayoutOrder() {
        let earlier = Zone(id: ZoneID(rawValue: 4), frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        let later = Zone(id: ZoneID(rawValue: 1), frame: CGRect(x: 60, y: 0, width: 40, height: 40))
        XCTAssertNil(ZoneSelectionEngine.select(point: CGPoint(x: 40, y: 10), zones: [earlier, later],
                                                workArea: CGRect(x: 0, y: 0, width: 100, height: 50), radius: 10))
        XCTAssertEqual(ZoneSelectionEngine.select(point: CGPoint(x: 50, y: 20), zones: [earlier, later],
                                                  workArea: CGRect(x: 0, y: 0, width: 100, height: 50), radius: 15)?.id,
                       earlier.id)
        XCTAssertNil(ZoneSelectionEngine.select(point: CGPoint(x: 50, y: 20), zones: [earlier, later],
                                                workArea: CGRect(x: 0, y: 0, width: 100, height: 50), radius: 0))
    }

    func testSingleExpandedZoneAndPointsOutsideEnvelopeOrWorkAreaStayEmpty() {
        let zone = Zone(id: ZoneID(rawValue: 0), frame: CGRect(x: 10, y: 10, width: 80, height: 30))
        let area = CGRect(x: 0, y: 0, width: 120, height: 60)
        XCTAssertNil(ZoneSelectionEngine.select(point: CGPoint(x: 95, y: 20), zones: [zone], workArea: area, radius: 10))
        XCTAssertNil(ZoneSelectionEngine.select(point: CGPoint(x: 5, y: 20), zones: [zone], workArea: area, radius: 10))
        XCTAssertNil(ZoneSelectionEngine.select(point: CGPoint(x: 121, y: 20), zones: [zone], workArea: area, radius: 10))
        XCTAssertNil(ZoneSelectionEngine.select(point: CGPoint(x: 120, y: 20), zones: [zone], workArea: area, radius: 10))
        XCTAssertEqual(ZoneSelectionEngine.select(point: CGPoint(x: 20, y: 20), zones: [zone], workArea: area, radius: 0)?.id, zone.id)
    }
}

final class DragSnapSettingsAndOverlayTests: XCTestCase {
    @MainActor
    func testToggleUsesOneAcceptedDownAndResetsAtGestureEnd() {
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [makeDisplay()], primaryFrame: makeDisplay().frame)))
        var settings = DragSettings()
        settings.toggleButton = 2
        layout.dragSettings = settings
        let snap = DragSnapController(layoutController: layout, runtime: FakeDragReader(), overlay: FakeZoneOverlay())
        XCTAssertFalse(snap.isActivated(flags: 0))
        snap.acceptedInput(DragInputEvent(kind: .buttonChanged, button: 2, buttonMask: 1 << 2, buttonEdge: .down))
        XCTAssertFalse(snap.isActivated(flags: 0), "A secondary DOWN without the primary drag button must be ignored.")
        let down = DragInputEvent(kind: .buttonChanged, button: 2, buttonMask: 1 | (1 << 2), buttonEdge: .down)
        snap.acceptedInput(down)
        snap.acceptedInput(down)
        XCTAssertTrue(snap.isActivated(flags: 0), "A repeated DOWN stays latched after exactly one toggle.")
        snap.acceptedInput(DragInputEvent(kind: .buttonChanged, button: 2, buttonMask: 1, buttonEdge: .released))
        snap.lifecycle(DragLifecycleEvent(kind: .ended, session: 1, frame: nil, reason: nil))
        XCTAssertFalse(snap.isActivated(flags: 0))
    }

    @MainActor
    func testShiftXorToggleTruthTableAndOnlyMappedSecondaryButtonsToggle() {
        let display = makeDisplay()
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)))
        let snap = DragSnapController(layoutController: layout, runtime: FakeDragReader(), overlay: FakeZoneOverlay())
        XCTAssertFalse(snap.isActivated(flags: 0))
        XCTAssertTrue(snap.isActivated(flags: CGEventFlags.maskShift.rawValue))
        var settings = DragSettings()
        settings.toggleButton = 4
        layout.dragSettings = settings
        snap.acceptedInput(DragInputEvent(kind: .buttonChanged, button: 4, buttonMask: 1 | (1 << 4), buttonEdge: .down))
        XCTAssertTrue(snap.isActivated(flags: 0))
        XCTAssertFalse(snap.isActivated(flags: CGEventFlags.maskShift.rawValue))

        for button in [UInt32(0), 5, 6] {
            snap.acceptedInput(DragInputEvent(kind: .buttonChanged, button: Int64(button),
                                              buttonMask: 1 | (UInt64(1) << UInt64(button)), buttonEdge: .down))
        }
        XCTAssertTrue(snap.isActivated(flags: 0), "Main/unmapped buttons must not change activation.")
        snap.acceptedInput(DragInputEvent(kind: .buttonChanged, button: 4, buttonMask: 1, buttonEdge: .released))
        settings.requireShift = false
        layout.dragSettings = settings
        XCTAssertFalse(snap.isActivated(flags: 0))
        XCTAssertTrue(snap.isActivated(flags: CGEventFlags.maskShift.rawValue))
        snap.acceptedInput(DragInputEvent(kind: .buttonChanged, button: 4, buttonMask: 1 | (1 << 4), buttonEdge: .down))
        XCTAssertTrue(snap.isActivated(flags: 0))
        XCTAssertFalse(snap.isActivated(flags: CGEventFlags.maskShift.rawValue))
    }

    @MainActor
    func testDisplaySnapshotAtoBtoAAdvancesRevisionAndInvalidatesTwice() throws {
        let first = makeDisplay()
        let second = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: first.persistentID,
                             sessionID: first.sessionID, name: "Changed display metadata", frame: first.frame,
                             workArea: CGRect(x: 0, y: 0, width: 980, height: 780), isPrimary: true,
                             backingScaleFactor: first.backingScaleFactor)
        let snapshotA = DisplaySnapshot(displays: [first], primaryFrame: first.frame)
        let snapshotB = DisplaySnapshot(displays: [second], primaryFrame: second.frame)
        let layout = LayoutController(displayProvider: DisplayProvider(snapshots: [snapshotA, snapshotB, snapshotA]))
        var invalidations = 0
        layout.invalidateDragCommit = { invalidations += 1 }
        let initialRevision = layout.dragLayoutRevision
        let atB = try XCTUnwrap(layout.appliedDragLayoutSnapshot(at: CGPoint(x: 10, y: 10)))
        let atA = try XCTUnwrap(layout.appliedDragLayoutSnapshot(at: CGPoint(x: 10, y: 10)))
        XCTAssertGreaterThan(atA.revision, atB.revision)
        XCTAssertEqual(invalidations, 2)
        XCTAssertGreaterThan(atA.revision, initialRevision)
    }

    @MainActor
    func testOverlayManagerReusesDisplayPanelsAndHidesOldDisplayWithoutCreatingAppKitPanels() throws {
        let first = makeDisplay()
        let second = Display(runtimeID: RuntimeDisplayID(rawValue: 2), persistentID: PersistentDisplayID(uuid: UUID()),
                             sessionID: UUID(), name: "Second", frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
                             workArea: CGRect(x: 1_000, y: 0, width: 1_000, height: 800), isPrimary: false,
                             backingScaleFactor: 1)
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [first, second], primaryFrame: first.frame)))
        let firstSnapshot = try XCTUnwrap(layout.appliedDragLayoutSnapshot(at: CGPoint(x: 10, y: 10)))
        let secondSnapshot = try XCTUnwrap(layout.appliedDragLayoutSnapshot(at: CGPoint(x: 1_010, y: 10)))
        let factory = FakeOverlayPanelFactory()
        let manager = ZoneOverlayManager(makePanel: { factory.make() })

        manager.show(firstSnapshot, selected: firstSnapshot.zones.first?.id)
        manager.show(firstSnapshot, selected: firstSnapshot.zones.first?.id)
        XCTAssertEqual(factory.panels.count, 1)
        XCTAssertEqual(factory.panels[0].showCount, 2)
        manager.show(secondSnapshot, selected: secondSnapshot.zones.first?.id)
        XCTAssertEqual(factory.panels.count, 2)
        XCTAssertFalse(factory.panels[0].visible)
        XCTAssertTrue(factory.panels[1].visible)
        manager.show(firstSnapshot, selected: nil)
        XCTAssertEqual(factory.panels.count, 2)
        XCTAssertTrue(factory.panels[0].visible)
        XCTAssertFalse(factory.panels[1].visible)
        manager.hideAll()
        XCTAssertTrue(factory.panels.allSatisfy { !$0.visible })
    }

    private func makeDisplay() -> Display {
        Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: PersistentDisplayID(uuid: UUID()),
                sessionID: UUID(), name: "Test", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800), isPrimary: true, backingScaleFactor: 1)
    }
}

@MainActor
final class FakeZoneOverlay: ZoneOverlayPresenting {
    private(set) var showCount = 0
    private(set) var isVisible = false
    private(set) var selected: ZoneID?
    func show(_ snapshot: DragLayoutSnapshot, selected: ZoneID?) {
        showCount += 1
        isVisible = true
        self.selected = selected
    }
    func hideAll() { isVisible = false; selected = nil }
}

@MainActor
private final class FakeOverlayPanelFactory {
    private(set) var panels: [FakeOverlayPanel] = []
    func make() -> any ZoneOverlayPanelPresenting {
        let panel = FakeOverlayPanel()
        panels.append(panel)
        return panel
    }
}

@MainActor
private final class FakeOverlayPanel: ZoneOverlayPanelPresenting {
    private(set) var showCount = 0
    private(set) var visible = false
    func show(display: Display, snapshot: DragLayoutSnapshot, selected: ZoneID?) { showCount += 1; visible = true }
    func hide() { visible = false }
}

@MainActor
final class TestDragGate {
    private(set) var commitActive = false
    func setDrag(_ value: Bool) { _ = value }
    func recordCommit(_ value: Bool) { commitActive = value }
}
